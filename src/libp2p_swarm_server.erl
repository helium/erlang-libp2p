-module(libp2p_swarm_server).

-behavior(gen_server).

-record(state, {
          tid :: ets:tab(),
          monitors=[] :: [{{reference(), pid()}, {atom(), string()}}]
         }).

-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

-export([dial/3, listen/2, connect/2,
         listen_addrs/1, add_connection_handler/3,
         add_stream_handler/3, stream_handlers/1]).

%%
%% API
%%

-spec dial(pid(), string(), string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Pid, Addr, Path) ->
    gen_server:call(Pid, {dial, Addr, Path}).

-spec connect(pid(), string()) ->{ok, pid()} | {error, term()}.
connect(Pid, Addr) ->
    gen_server:call(Pid, {connect_to, Addr}).

-spec listen(pid(), string()) -> ok | {error, term()}.
listen(Pid, Addr) ->
    {ok, _, {ListenAddr, _}} = libp2p_transport:for_addr(Addr),
    gen_server:call(Pid, {listen, ListenAddr}).

-spec listen_addrs(pid()) -> [string()].
listen_addrs(Pid) ->
    gen_server:call(Pid, listen_addrs).

-spec add_connection_handler(pid(), string(), {libp2p_transport:connection_handler(), libp2p_transport:connection_handler()}) -> ok.
add_connection_handler(Pid, Key, HandlerDef) ->
    gen_server:call(Pid, {add_connection_handler, {Key, HandlerDef}}).

-spec add_stream_handler(pid(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Pid, Key, HandlerDef) ->
    gen_server:call(Pid, {add_stream_handler, {Key, HandlerDef}}).

-spec stream_handlers(pid()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Pid) ->
    gen_server:call(Pid, stream_handlers).

%%
%% gen_server
%%

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),
    % Register the a default connection handler
    DefConnHandler = {"yamux/1.0.0",
                      {libp2p_yamux_session, start_server},
                      {libp2p_yamux_session, start_client}},
    libp2p_config:insert_connection_handler(TID, DefConnHandler),
    IdentifyHandler = {"identify/1.0.0", {libp2p_stream_identify, enter_loop}},
    libp2p_config:insert_stream_handler(TID, IdentifyHandler),
    {ok, #state{tid=TID}}.

handle_call({listen, Addr}, _From, State=#state{tid=TID}) ->
    case listen_on(TID, Addr, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, NewState} -> {reply, ok, NewState}
    end;
handle_call(listen_addrs, _From, State=#state{tid=TID}) ->
    {reply, libp2p_config:listen_addrs(TID), State};
handle_call({dial, Addr, Path}, _From, State=#state{tid=TID}) ->
    case connect_to(TID, Addr, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, SessionPid, NewState} ->
            case start_client_stream(TID, Path, SessionPid) of
                {error, Error} -> {error, Error};
                {ok, Connection} -> {reply, {ok, Connection}, NewState}
            end
    end;
handle_call({connect_to, Addr}, _From, State=#state{tid=TID}) ->
    case connect_to(TID, Addr, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, SessionPid, NewState} -> {reply, {ok, SessionPid}, NewState}
    end;
handle_call({add_connection_handler, HandlerDef}, _From, State=#state{tid=TID}) ->
    libp2p_config:insert_connection_handler(TID, HandlerDef),
    {reply, ok, State};
handle_call({add_stream_handler, HandlerDef}, _From, State=#state{tid=TID}) ->
    libp2p_config:insert_stream_handler(TID, HandlerDef),
    {reply, ok, State};
handle_call(stream_handlers, _From, State=#state{tid=TID}) ->
    {reply, libp2p_config:lookup_stream_handlers(TID), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p~n", [Msg]),
    {reply, ok, State}.

handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{}) ->
    {noreply, remove_monitor(MonitorRef, Pid, State)};
handle_info({'EXIT', _From,  Reason}, State=#state{}) ->
    {stop, Reason, State};
handle_info(Msg, _State) ->
    lager:warning("Unhandled message ~p", [Msg]).

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p~n", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{tid=TID}) ->
    lists:foreach(fun({Addr, Pid}) ->
                          libp2p_config:remove_session(TID, Addr),
                          catch libp2p_session:close(Pid)
                  end, libp2p_config:lookup_sessions(TID)).

%%
%% Internal
%%

-spec add_monitor(atom(), [string()], pid(), #state{}) -> #state{}.
add_monitor(Kind, Addrs, Pid, State=#state{monitors=Monitors}) ->
    MonitorRef = erlang:monitor(process, Pid),
    State#state{monitors=[{{MonitorRef, Pid}, {Kind, Addrs}} | Monitors]}.

-spec remove_monitor(reference(), pid(), #state{}) -> #state{}.
remove_monitor(MonitorRef, Pid, State=#state{tid=TID, monitors=Monitors}) ->
    case lists:keytake({MonitorRef, Pid}, 1, Monitors) of
        false -> State;
        {value, {_, {Kind, Addrs}}, NewMonitors} ->
            lists:foreach(fun(Addr) -> libp2p_config:remove_pid(TID, Kind, Addr) end, Addrs),
            State#state{monitors=NewMonitors}
    end.

-spec listen_on(ets:tab(), string(), #state{}) -> {ok, #state{}} | {error, term()}.
listen_on(TID, Addr, State=#state{}) ->
    {ok, Transport, {ListenAddr, []}} = libp2p_transport:for_addr(Addr),
    case libp2p_config:lookup_listener(TID, Addr) of
        {ok, _Pid} -> {error, already_listening};
        false ->
            ListenerSup = listener_sup(TID),
            case Transport:start_listener(ListenerSup, ListenAddr, TID) of
                {ok, TransportAddrs, ListenPid} ->
                    lager:info("Started Listener on ~p", [TransportAddrs]),
                    lager:debug(lists:map(fun(TAddr) -> libp2p_config:insert_listener(TID, TAddr, ListenPid) end, TransportAddrs)),
                    Kind = hd(lists:map(fun(TAddr) -> libp2p_config:insert_listener(TID, TAddr, ListenPid) end, TransportAddrs)),
                    {ok, add_monitor(Kind, TransportAddrs, ListenPid, State)};
                {error, Error} ->
                    lager:error("Failed to start listener on ~p: ~p", [ListenAddr, Error]),
                    {error, Error}
            end
    end.


-spec connect_to(ets:tab(), string(), #state{})
                -> {ok, libp2p_session:pid(), #state{}} | {error, term()}.
connect_to(TID, Addr, State) ->
    {ok, Transport, {ConnAddr, _}} = libp2p_transport:for_addr(Addr),
    case libp2p_config:lookup_session(TID, ConnAddr) of
        {ok, Pid} -> {ok, Pid, State};
        false ->
            lager:info("Connecting to ~p", [ConnAddr]),
            case Transport:dial(ConnAddr) of
                {error, Error} ->
                    lager:error("Failed to connect to ~p: ~p", [ConnAddr, Error]),
                    {error, Error};
                {ok, Connection} ->
                    lager:info("Starting client session with ~p", [ConnAddr]),
                    case start_client_session(TID, ConnAddr, Connection) of
                        {error, Error} -> {error, Error};
                        {ok, Kind, SessionPid} ->
                            {ok, SessionPid, add_monitor(Kind, [ConnAddr], SessionPid, State)}
                    end
            end
    end.

-spec start_client_stream(ets:tab(), string(), libp2p_session:pid())
                         -> {ok, libp2p_connection:connection()} | {error, term()}.
start_client_stream(_TID, Path, SessionPid) ->
    case libp2p_session:open(SessionPid) of
        {error, Error} -> {error, Error};
        {ok, Connection} ->
            Handlers = [{Path, undefined}],
            case libp2p_multistream_client:negotiate_handler(Handlers, "stream", Connection) of
                {error, Error} -> {error, Error};
                {ok, _} -> {ok, Connection}
            end
    end.

-spec start_client_session(ets:tab(), string(), libp2p_connection:connection())
                          -> {ok, atom(), libp2p_session:pid()} | {error, term()}.
start_client_session(TID, Addr, Connection) ->
    Handlers = libp2p_config:lookup_connection_handlers(TID),
    case libp2p_multistream_client:negotiate_handler(Handlers, Addr, Connection) of
        {error, Error} -> {error, Error};
        {ok, {_, {M, F}}} ->
            ChildSpec = #{ id => Addr,
                           start => {M, F, [Connection, [], TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            SessionSup = session_sup(TID),
            {ok, SessionPid} = supervisor:start_child(SessionSup, ChildSpec),
            Kind = libp2p_config:insert_session(TID, Addr, SessionPid),
            case libp2p_connection:controlling_process(Connection, SessionPid) of
                ok -> {ok, Kind, SessionPid};
                {error, Error} ->
                    libp2p_connection:close(Connection),
                    {error, Error}
            end
    end.

listener_sup(TID) ->
    libp2p_swarm_listener_sup:sup(TID).

session_sup(TID) ->
    libp2p_swarm_session_sup:sup(TID).
