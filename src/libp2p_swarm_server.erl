-module(libp2p_swarm_server).

-behavior(gen_server).

-record(state,
        { tid :: ets:tab(),
          sig_fun :: libp2p_crypto:sig_fun(),
          ecdh_fun :: libp2p_crypto:ecdh_fun(),
          pid_gc_monitor = make_ref() :: reference(),
          monitors=#{} :: #{pid() => {reference(), atom()}}
         }).

-export([start_link/3, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

%% gen_server
%%

start_link(TID, SigFun, ECDHFun) ->
    gen_server:start_link(reg_name(TID), ?MODULE, [TID, SigFun, ECDHFun], []).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

init([TID, SigFun, ECDHFun]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_server(TID),
    % Add tcp and p2p as a default transports
    libp2p_swarm:add_transport_handler(TID, libp2p_transport_tcp),
    libp2p_swarm:add_transport_handler(TID, libp2p_transport_p2p),
    libp2p_swarm:add_transport_handler(TID, libp2p_transport_relay),
    % Register the default connection handler
    libp2p_swarm:add_connection_handler(TID, "yamux/1.0.0", {{libp2p_yamux_session, start_server},
                                                             {libp2p_yamux_session, start_client}}),
    libp2p_swarm:add_connection_handler(TID, libp2p_proxy:version(), {{libp2p_proxy_session, start_server},
                                                                      undefined}), %% no client side registration
    % Register default stream handlers
    libp2p_swarm:add_stream_handler(TID, "identify/1.0.0",
                                    {libp2p_stream_identify, server, []}),

    erlang:send_after(timer:minutes(5), self(), gc_pids),

    {ok, #state{tid=TID, sig_fun=SigFun, ecdh_fun=ECDHFun}}.

handle_call(tid, _From, State=#state{tid=TID}) ->
    {reply, TID, State};
handle_call(keys, _From, State=#state{tid=TID, sig_fun=SigFun, ecdh_fun=ECDHFun}) ->
    PubKey = libp2p_crypto:bin_to_pubkey(libp2p_swarm:pubkey_bin(TID)),
    {reply, {ok, PubKey, SigFun, ECDHFun}, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_info(gc_pids, State=#state{tid=TID}) ->
    Parent = self(),
    {_Pid, Ref} = spawn_monitor(fun() ->
                          libp2p_config:gc_pids(TID),
                          Parent ! gc_pids_done
                  end),
    {noreply, State#state{pid_gc_monitor=Ref}};
handle_info(gc_pids_done, State) ->
    erlang:send_after(timer:minutes(5), self(), gc_pids),
    erlang:demonitor(State#state.pid_gc_monitor, [flush]),
    {noreply, State};
handle_info({handle_identify, Session, {error, Error}}, State=#state{}) ->
    {_, PeerAddr} = libp2p_session:addr_info(State#state.tid, Session),
    lager:warning("ignoring session after failed identify ~p: ~p", [PeerAddr, Error]),
    {noreply, State};
handle_info({handle_identify, Session, {ok, Identify}}, State=#state{tid=TID}) ->
    %% Response from an identify triggered by `register_session.
    %%
    %% Store the session in config and tell the peerbook about the
    %% session change as well as the new identify record.
    spawn(fun() ->
    Addr = libp2p_crypto:pubkey_bin_to_p2p(libp2p_identify:pubkey_bin(Identify)),
    lager:debug("received identity for peer ~p. Putting this peer", [Addr]),
    PeerBook = libp2p_swarm:peerbook(TID),
    try libp2p_peerbook:put(PeerBook, [libp2p_identify:peer(Identify)]) of
        ok ->
            libp2p_config:insert_session(TID,
                                         Addr,
                                         Session),
            libp2p_peerbook:register_session(PeerBook, Session, Identify);
        {error, Reason} ->
            lager:warning("Failed to put peerbook entry for ~p ~p", [Addr, Reason]),
            libp2p_session:close(Session)
    catch
        error:invalid_signature ->
            lager:warning("Invalid peerbook signature for ~p", [Addr]),
            libp2p_session:close(Session)
    end
          end),
    {noreply, State};
handle_info({'DOWN', MonitorRef, process, _Pid, _Reason}, State=#state{pid_gc_monitor=MonitorRef}) ->
    erlang:send_after(timer:minutes(5), self(), gc_pids),
    {noreply, State};
handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{tid=TID}) ->
    NewState = remove_monitor(MonitorRef, Pid, State),
    spawn(fun() ->
    libp2p_config:remove_pid(TID, Pid),
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:unregister_session(PeerBook, Pid)
          end),
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
    %% start_server_session and start_client_session.
    %%
    %% Called from listeners getting started with Kind ==
    %% libp2p_config:listener()
    %%
    %% The actual peerbook registration doesn't happen
    %% until we receive an identify message.
    case Kind == libp2p_config:session() of
        true -> libp2p_session:identify(SessionPid, self(), SessionPid);
        _ -> ok
    end,
    NewState = add_monitor(Kind, SessionPid, State),
    {noreply, NewState};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:warning("going down ~p", [Reason]),
    ok.

%% Internal
%%

-spec add_monitor(atom(), pid(), #state{}) -> #state{}.
add_monitor(Kind, Pid, State=#state{monitors=Monitors}) ->
    Value = case maps:find(Pid, Monitors) of
                error -> {erlang:monitor(process, Pid), Kind};
                {ok, {MonitorRef, Kind}} -> {MonitorRef, Kind}
            end,
    State#state{monitors=Monitors#{Pid => Value}}.

-spec remove_monitor(reference(), pid(), #state{}) -> #state{}.
remove_monitor(MonitorRef, Pid, State=#state{tid=TID, monitors=Monitors}) ->
    case maps:find(Pid, Monitors) of
        error -> State;
        {ok, {MonitorRef, _}} ->
            libp2p_config:remove_pid(TID, Pid),
            State#state{monitors=maps:remove(Pid, Monitors)}
    end.
