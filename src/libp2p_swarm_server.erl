-module(libp2p_swarm_server).

-behavior(gen_server).

-record(state,
        { tid :: ets:tab(),
          sig_fun :: libp2p_crypto:sig_fun(),
          monitors=[] :: [{pid(), {reference(), atom()}}]
         }).

-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

%% gen_server
%%

start_link(TID, SigFun) ->
    gen_server:start_link(?MODULE, [TID, SigFun], []).

init([TID, SigFun]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_server(TID),
    % Add tcp and p2p as a default transports
    libp2p_swarm:add_transport_handler(TID, libp2p_transport_tcp),
    libp2p_swarm:add_transport_handler(TID, libp2p_transport_p2p),
    libp2p_swarm:add_transport_handler(TID, libp2p_transport_relay),
    % Register the default connection handler
    libp2p_swarm:add_connection_handler(TID, "yamux/1.0.0",
                                        {{libp2p_yamux_session, start_server},
                                         {libp2p_yamux_session, start_client}}),
    % Register default stream handlers
    libp2p_swarm:add_stream_handler(TID, "identify/1.0.0",
                                    {libp2p_stream_identify, server, []}),
    libp2p_swarm:add_stream_handler(TID, "peer/1.0.0",
                                    {libp2p_framed_stream, server, [libp2p_stream_peer, TID]}),

    {ok, #state{tid=TID, sig_fun=SigFun}}.

handle_call(tid, _From, State=#state{tid=TID}) ->
    {reply, TID, State};
handle_call(keys, _From, State=#state{tid=TID, sig_fun=SigFun}) ->
    PubKey = libp2p_crypto:address_to_pubkey(libp2p_swarm:address(TID)),
    {reply, {ok, PubKey, SigFun}, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_info({identify, Kind, Session, Identify}, State=#state{tid=TID}) ->
    %% Response from a connect_to or accept initiated
    %% spawn_identify. Register the connection in peerbook
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:register_session(PeerBook, Session, Identify, Kind),
    libp2p_config:insert_session(TID, p2p_address(libp2p_identify:address(Identify)), Session),
    {noreply, State};
handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{tid=TID}) ->
    NewState = remove_monitor(MonitorRef, Pid, State),
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:unregister_session(PeerBook, Pid),
    {noreply, NewState};
handle_info({'EXIT', _From,  Reason}, State=#state{}) ->
    {stop, Reason, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled message ~p", [Msg]),
    {noreply, State}.


handle_cast({register, Kind, SessionPid}, State=#state{}) ->
    %% Called with Kind == libp2p_config:session() from listeners
    %% accepting connections. This is called through
    %% libp2p_swarm:register_session, for example, from
    %% start_server_session and start_client_session. The actual
    %% peerbook registration doesn't happen until we receive an
    %% identify message.
    %%
    %% Called from listeners getting started with Kind ==
    %% libp2p_config:listener()
    NewState = add_monitor(Kind, SessionPid, State),
    {noreply, NewState};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


terminate(Reason, #state{tid=TID}) ->
    lists:foreach(fun({Addr, Pid}) ->
                          libp2p_config:remove_session(TID, Addr),
                          catch libp2p_session:close(Pid, Reason, infinity)
                  end, libp2p_config:lookup_sessions(TID)).

%% Internal
%%

-spec add_monitor(atom(), pid(), #state{}) -> #state{}.
add_monitor(Kind, Pid, State=#state{monitors=Monitors}) ->
    Value = case lists:keyfind(Pid, 1, Monitors) of
                false -> {erlang:monitor(process, Pid), Kind};
                {Pid, {MonitorRef, Kind}} -> {MonitorRef, Kind}
            end,
    State#state{monitors=lists:keystore(Pid, 1, Monitors, {Pid, Value})}.

-spec remove_monitor(reference(), pid(), #state{}) -> #state{}.
remove_monitor(MonitorRef, Pid, State=#state{tid=TID, monitors=Monitors}) ->
    case lists:keytake(Pid, 1, Monitors) of
        false -> State;
        {value, {Pid, {MonitorRef, _Kind}}, NewMonitors} ->
            libp2p_config:remove_pid(TID, Pid),
            State#state{monitors=NewMonitors}
    end.


-spec p2p_address(binary()) -> string().
p2p_address(Address) when is_binary(Address) ->
    "/p2p/" ++ libp2p_crypto:address_to_b58(Address).
