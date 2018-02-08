-module(libp2p_swarm_server).

-behavior(gen_server).

-record(state, {
          tid :: ets:tab(),
          monitors=[] :: [{{reference(), pid()}, {atom(), term()}}],
          observed_addresses=[] :: [{string(), string()}],
          stun_txn_ids = #{}
         }).

-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

-export([dial/5, listen/2, connect/4,
         listen_addrs/1, add_connection_handler/3,
         add_external_listen_addr/3, record_observed_address/3, stungun_response/3,
         add_stream_handler/3, stream_handlers/1]).

-define(DIAL_TIMEOUT, 5000).

%%
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

-spec add_connection_handler(pid(), string(), {libp2p_transport:connection_handler(), libp2p_transport:connection_handler()}) -> ok.
add_connection_handler(Pid, Key, HandlerDef) ->
    gen_server:call(Pid, {add_connection_handler, {Key, HandlerDef}}).

-spec add_stream_handler(pid(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Pid, Key, HandlerDef) ->
    gen_server:call(Pid, {add_stream_handler, {Key, HandlerDef}}).

-spec stream_handlers(pid()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Pid) ->
    gen_server:call(Pid, stream_handlers).

-spec add_external_listen_addr(pid(), string(), string()) -> ok.
add_external_listen_addr(Pid, MA, Address) ->
    gen_server:cast(Pid, {add_listen_addr, MA, Address}).

record_observed_address(Pid, PeerAddr, Address) ->
    gen_server:cast(Pid, {record_observed_address, PeerAddr, Address}).

stungun_response(Pid, LocalAddr, STUNTxnID) ->
    gen_server:cast(Pid, {stungun_response, LocalAddr, STUNTxnID}).
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
    IdentifyHandler = {"identify/1.0.0", {libp2p_stream_identify, server}},
    libp2p_config:insert_stream_handler(TID, IdentifyHandler),
    StungunHandler = {"stungun/1.0.0", {libp2p_stream_stungun, server}},
    libp2p_config:insert_stream_handler(TID, StungunHandler),
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
            case start_client_stream(TID, Path, SessionPid) of
                {error, Error} -> {error, Error};
                {ok, Connection} -> {reply, {ok, Connection}, NewState}
            end
    end;
handle_call({connect_to, Addr, Options, Timeout}, _From, State=#state{}) ->
    case connect_to(Addr, Options, Timeout, State) of
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

handle_info({stungun_timeout, TxnID}, State=#state{stun_txn_ids=STUNTxnMap}) ->
    {noreply, State#state{stun_txn_ids= maps:filter(fun(_, {T, _}) when T == TxnID -> false;
                                                       (_, _) -> true
                                                    end, STUNTxnMap)}};
handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{}) ->
    {noreply, remove_monitor(MonitorRef, Pid, State)};
handle_info({'EXIT', _From,  Reason}, State=#state{}) ->
    {stop, Reason, State};
handle_info(Msg, _State) ->
    lager:warning("Unhandled message ~p", [Msg]).

handle_cast({add_listen_addr, IntAddress, ExtAddress}, State=#state{tid=TID}) ->
    case libp2p_config:lookup_listener(TID, IntAddress) of
        {ok, ListenPid} ->
            libp2p_config:insert_listener(TID, ExtAddress, ListenPid),
            {noreply, State};
        _ ->
            {noreply, State}
    end;
handle_cast({record_observed_address, PeerAddress, ObservedAddress}, State=#state{tid=TID}) ->
    case libp2p_config:lookup_listener(TID, ObservedAddress) of
        false ->
            %% ok, check if we've observed this address before
            case lists:member({PeerAddress, ObservedAddress} ,State#state.observed_addresses) of
                true ->
                    %% this peer has already told us we have this address
                    {noreply, State};
                false ->
                    case lists:keymember(ObservedAddress, 2, State#state.observed_addresses) of
                        true ->
                            %% ok, we have independant confirmation of an observed address
                            lager:info("received confirmation of observed address ~s", [ObservedAddress]),
                            %% TODO attempt STUN dial-in and see if it works
                            <<STUNTxnID:96/integer-unsigned-little>> = crypto:strong_rand_bytes(12),
                            %% we need to record this TxnID somewhere, probably in the TID and then we need to convince a peer to dial us back with that TxnID
                            %% then that handler needs to forward the response back here, so we can add the external address
                            Parent = self(),
                            spawn(fun() ->
                                          {ok, C} = libp2p_swarm_server:dial(Parent, PeerAddress, lists:flatten(io_lib:format("stungun/1.0.0/dial/~b", [STUNTxnID])), [], ?DIAL_TIMEOUT),
                                          libp2p_framed_stream:client(libp2p_stream_stungun, C, [Parent])
                                  end),
                            Ref = erlang:send_after(500, self(), {stungun_timeout, STUNTxnID}),
                            STUNTxnMap = maps:put(Ref, {STUNTxnID, ObservedAddress}, State#state.stun_txn_ids),
                            {noreply, State#state{observed_addresses=[{PeerAddress, ObservedAddress}|State#state.observed_addresses], stun_txn_ids=STUNTxnMap}};
                        false ->
                            lager:info("peer ~p informed us of our observed address ~p", [PeerAddress, ObservedAddress]),
                            {noreply, State#state{observed_addresses=[{PeerAddress, ObservedAddress}|State#state.observed_addresses]}}
                    end
            end;
        {ok, _} ->
            %% we already know about this observed address, not much to do, I guess
            {noreply, State#state{observed_addresses=[{PeerAddress, ObservedAddress}|State#state.observed_addresses]}}
    end;
handle_cast({stungun_response, LocalAddr, STUNTxnID}, State=#state{stun_txn_ids=STUNTxnMap, tid=TID}) ->
    case lists:keyfind(STUNTxnID, 1, maps:values(STUNTxnMap)) of
        {STUNTxnID, ObservedAddress} ->
            lager:info("Got dial back confirmation of observed address ~p", [ObservedAddress]),
            case libp2p_config:lookup_listener(TID, LocalAddr) of
                {ok, ListenerPid} ->
                    libp2p_config:insert_listener(TID, ObservedAddress, ListenerPid);
                false ->
                    lager:warning("unable to determine listener pid for ~p", [LocalAddr])
            end,
            ok;
        false ->
            ok
    end,
    {noreply, State#state{stun_txn_ids= maps:filter(fun(_, {TxnID, _}) when TxnID == STUNTxnID -> false;
                                                       (_, _) -> true
                                                    end, STUNTxnMap)}};
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

-spec listen_on(string(), #state{}) -> {ok, #state{}} | {error, term()}.
listen_on(Addr, State=#state{tid=TID}) ->
    case libp2p_transport:for_addr(Addr) of
        {ok, Transport, {ListenAddr, []}} ->
            case libp2p_config:lookup_listener(TID, Addr) of
                {ok, _} -> {error, already_listening};
                false ->
                    ListenerSup = listener_sup(TID),
                    case Transport:start_listener(ListenerSup, ListenAddr, TID) of
                        {ok, TransportAddrs, ListenPid} ->
                            lager:info("Started Listener on ~p", [TransportAddrs]),
                            lists:foreach(fun(A) ->
                                                  libp2p_config:insert_listener(TID, A, ListenPid)
                                          end, TransportAddrs),
                            {ok, add_monitor(libp2p_config:listener(),
                                             TransportAddrs, ListenPid, State)};
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
    case libp2p_transport:for_addr(Addr) of
        {ok, Transport, {ConnAddr, _}} ->
            case libp2p_config:lookup_session(TID, ConnAddr, Options) of
                {ok, Pid} ->
                    {ok, Pid, State};
                false ->
                    ListenAddrs = libp2p_config:listen_addrs(TID),
                    PortOptions = case proplists:get_value(unique, Options) of
                                      true ->
                                          [];
                                      _ ->
                                          {ok, PO} = find_matching_listen_port(multiaddr:new(Addr), ListenAddrs),
                                          PO
                                  end,
                    lager:info("Connecting to ~p", [ConnAddr]),
                    case Transport:dial(ConnAddr, Options++PortOptions, Timeout) of
                        {error, Error} ->
                            {error, Error};
                        {ok, Connection} ->
                            case start_client_session(TID, ConnAddr, Connection) of
                                {error, SessionError} -> {error, SessionError};
                                {ok, SessionPid} ->
                                    Parent = self(),
                                    spawn(fun() -> Transport:discover(libp2p_swarm_sup:sup(TID), Parent, Addr) end),
                                    {ok, SessionPid,
                                     add_monitor(libp2p_config:session(),
                                                 [ConnAddr], SessionPid, State)}
                            end
                    end
            end;
        {error, Error} -> {error, Error}
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
                          -> {ok, libp2p_session:pid()} | {error, term()}.
start_client_session(TID, Addr, Connection) ->
    Handlers = libp2p_config:lookup_connection_handlers(TID),
    case libp2p_multistream_client:negotiate_handler(Handlers, Addr, Connection) of
        {error, Error} -> {error, Error};
        {ok, {_, {M, F}}} ->
            ChildSpec = #{ id => make_ref(),
                           start => {M, F, [Connection, [], TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            SessionSup = session_sup(TID),
            {ok, SessionPid} = supervisor:start_child(SessionSup, ChildSpec),
            libp2p_config:insert_session(TID, Addr, SessionPid),
            case libp2p_connection:controlling_process(Connection, SessionPid) of
                ok -> {ok, SessionPid};
                {error, Error} ->
                    libp2p_connection:close(Connection),
                    {error, Error}
            end
    end.

listener_sup(TID) ->
    libp2p_swarm_listener_sup:sup(TID).

session_sup(TID) ->
    libp2p_swarm_session_sup:sup(TID).

find_matching_listen_port(_Addr, []) ->
    {ok, []};
find_matching_listen_port(Addr, [H|ListenAddrs]) ->
    TheirAddr = multiaddr:new(H),
    MyProtocols = [ element(1, T) || T <- multiaddr:protocols(Addr)],
    TheirProtocols = [ element(1, T) || T <- multiaddr:protocols(TheirAddr)],
    case MyProtocols == TheirProtocols of
        true ->
            %% TODO we assume the port is the second element of the second tuple, this is not safe
            {ok, [{port, list_to_integer(element(2, lists:nth(2, multiaddr:protocols(TheirAddr))))}]};
        false ->
            find_matching_listen_port(Addr, ListenAddrs)
    end.
