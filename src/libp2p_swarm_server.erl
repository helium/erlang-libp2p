-module(libp2p_swarm_server).

-behavior(gen_server).

-record(state, {
          tid :: ets:tab(),
          monitors=[] :: [{{reference(), pid()}, {atom(), term()}}]
         }).

-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

-export([dial/5, listen/2, connect/4,
         add_transport_handler/2,
         listen_addrs/1, add_connection_handler/3,
         add_stream_handler/3, stream_handlers/1]).

-define(DIAL_TIMEOUT, 5000).

%% API
%%

-spec dial(pid(), string(), string(), [libp2p_swarm:connect_opt()], pos_integer())
          -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Pid, Addr, Path, Options, Timeout) ->
    gen_server:call(Pid, {dial, Addr, Path, Options, Timeout}, infinity).

-spec connect(pid(), string(), [libp2p_swarm:connect_opt()], pos_integer())
             ->{ok, pid()} | {error, term()}.
connect(Pid, Addr, Options, Timeout) ->
    gen_server:call(Pid, {connect_to, Addr, Options, Timeout}, infinity).

-spec listen(pid(), string()) -> ok | {error, term()}.
listen(Pid, Addr) ->
    gen_server:call(Pid, {listen, Addr}, infinity).

-spec listen_addrs(pid()) -> [string()].
listen_addrs(Pid) ->
    gen_server:call(Pid, listen_addrs).

-spec stream_handlers(pid()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Pid) ->
    gen_server:call(Pid, stream_handlers).


-spec add_transport_handler(pid(), atom()) -> ok.
add_transport_handler(Pid, Transport) ->
    gen_server:cast(Pid, {add_transport_handler, Transport}),
    ok.

-spec add_connection_handler(pid(), string(), {libp2p_transport:connection_handler(), libp2p_transport:connection_handler()}) -> ok.
add_connection_handler(Pid, Key, {ServerMF, ClientMF}) ->
    gen_server:cast(Pid, {add_connection_handler, {Key, ServerMF, ClientMF}}),
    ok.

-spec add_stream_handler(pid(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Pid, Key, ServerMF) ->
    gen_server:cast(Pid, {add_stream_handler, {Key, ServerMF}}),
    ok.

%% gen_server
%%

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),
    % Add tcp as a default transport
    add_transport_handler(self(), libp2p_transport_tcp),
    % Register the default connection handler
    add_connection_handler(self(), "yamux/1.0.0",
                           {{libp2p_yamux_session, start_server},
                            {libp2p_yamux_session, start_client}}),
    % Register default stream handlers
    add_stream_handler(self(), "identify/1.0.0",
                       {libp2p_stream_identify, server, []}),

    {ok, #state{tid=TID}}.

handle_call({listen, Addr}, _From, State=#state{}) ->
    case listen_on(Addr, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, NewState} -> {reply, ok, NewState}
    end;
handle_call(listen_addrs, _From, State=#state{tid=TID}) ->
    {reply, libp2p_config:listen_addrs(TID), State};
handle_call({dial, Addr, Path, Options, Timeout}, _From, State=#state{tid=TID}) ->
    case connect_to(Addr, Options, Timeout, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, SessionPid, NewState} ->
            case libp2p_session:start_client_stream(TID, Path, SessionPid) of
                {error, Error} -> {reply, {error, Error}, NewState};
                {ok, Connection} -> {reply, {ok, Connection}, NewState}
            end
    end;
handle_call({connect_to, Addr, Options, Timeout}, _From, State=#state{}) ->
    case connect_to(Addr, Options, Timeout, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, SessionPid, NewState} -> {reply, {ok, SessionPid}, NewState}
    end;
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


handle_cast({add_transport_handler, Transport}, State=#state{}) ->
    case start_transport(Transport, State) of
        {error, Error} -> error(Error);
        _ -> ok
    end,
    {noreply, State};
handle_cast({add_connection_handler, HandlerDef}, State=#state{tid=TID}) ->
    libp2p_config:insert_connection_handler(TID, HandlerDef),
    {noreply, State};
handle_cast({add_stream_handler, HandlerDef}, State=#state{tid=TID}) ->
    libp2p_config:insert_stream_handler(TID, HandlerDef),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p~n", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{tid=TID}) ->
    lists:foreach(fun({Addr, Pid}) ->
                          libp2p_config:remove_session(TID, Addr),
                          catch libp2p_session:close(Pid)
                  end, libp2p_config:lookup_sessions(TID)).

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

-spec start_transport(atom(), #state{}) -> {ok, pid()} | {error, term()}.
start_transport(Transport, #state{tid=TID}) ->
    case libp2p_config:lookup_transport(TID, Transport) of
        {ok, Pid} -> {ok, Pid};
        false ->
            TransportSup = libp2p_swarm_transport_sup:sup(TID),
            ChildSpec = #{ id => Transport,
                           start => {Transport, start_link, [TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            case supervisor:start_child(TransportSup, ChildSpec) of
                {error, Error} -> {error, Error};
                {ok, TransportPid} ->
                    libp2p_config:insert_transport(TID, Transport, TransportPid),
                    {ok, TransportPid}
            end
    end.

-spec listen_on(string(), #state{}) -> {ok, #state{}} | {error, term()}.
listen_on(Addr, State=#state{tid=TID}) ->
    case libp2p_transport:for_addr(TID, Addr) of
        {ok, ListenAddr, {Transport, TransportPid}} ->
            case libp2p_config:lookup_listener(TID, Addr) of
                {ok, _} -> {error, already_listening};
                false ->
                    case Transport:start_listener(TransportPid, ListenAddr) of
                        {ok, TransportAddrs, ListenPid} ->
                            lager:info("Started Listener on ~p", [TransportAddrs]),
                            lists:foreach(fun(A) ->
                                                  libp2p_config:insert_listener(TID, A, ListenPid)
                                          end, TransportAddrs),
                            {ok, add_monitor(libp2p_config:listener(),
                                             TransportAddrs, ListenPid, State)};
                        {error, Error={{shutdown, _}, _}} ->
                            % We don't log shutdown errors to avoid cluttering the logs
                            % whth confusing messages.
                            {error, Error};
                        {error, Error} ->
                            lager:error("Failed to start listener on ~p: ~p", [ListenAddr, Error]),
                            {error, Error}
                    end
            end;
        {error, Reason} -> {error, Reason}
    end.


-spec connect_to(string(), [libp2p_swarm:connect_opt()], pos_integer(), #state{})
                -> {ok, libp2p_session:pid(), #state{}} | {error, term()}.
connect_to(Addr, Options, Timeout, State=#state{tid=TID}) ->
    case libp2p_transport:for_addr(TID, Addr) of
        {ok, ConnAddr, {Transport, TransportPid}} ->
            case libp2p_config:lookup_session(TID, ConnAddr, Options) of
                {ok, Pid} ->
                    {ok, Pid, State};
                false ->
                    lager:info("Connecting to ~p", [ConnAddr]),
                    case Transport:connect(TransportPid, ConnAddr, Options, Timeout) of
                        {error, Error} ->
                            {error, Error};
                        {ok, SessionPid} ->
                            {ok, SessionPid,
                             add_monitor(libp2p_config:session(),
                                         [ConnAddr], SessionPid, State)}
                    end
            end;
        {error, Error} -> {error, Error}
    end.
