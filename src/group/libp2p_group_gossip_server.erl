-module(libp2p_group_gossip_server).

-record(state,
       { tid :: ets:tab(),
         peerbook_connections :: pos_integer(),
         seed_nodes :: [string()],
         client_specs :: [client_spec()],
         drop_timeout :: pos_integer(),
         drop_timer :: reference(),
         monitors=[] :: [monitor_entry()]
       }).

%% API
%%

assign_target(Pid, Kind, WorkerPid) ->
    gen_server:cast(Pid, {assign_target, Kind, WorkerPid}).


%% gen_server
%%

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),
    Opts = libp2p_swarm:opts(TID, []),
    PeerBookCount = libp2p_config:get_opt(Opts, [?MODULE, peerbook_connections],
                                          ?DEFAULT_PEERBOOK_CONNECTIONS),
    DropTimeOut = libp2p_config:get_opt(Opts, [?MODULE, drop_timeout], ?DEFAULT_DROP_TIMEOUT),
    ClientSpecs = libp2p_config:get_opt(Opts, [?MODULE, stream_clients], []),
    SeedNodes = libp2p_config:get_opt(Opts, [?MODULE, seed_nodes], []),
    self() ! {start_workers, PeerBookCount, length(SeedNodes},
    {ok, #state{tid= TID, seed_nodes=SeedNodes, client_specs=ClientSpecs
                drop_timeout=DropTimeOut, drop_timer=schedule_drop_timer(DropTimeOut)}}.

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({assign_target, Kind=peerbook, WorkerPid}, State#state{tid=TID}) ->
    PeerAddrs = libp2p_peerbook:keys(libp2p_swarm:peerbook(TID)),
    %% Get currently connected addresses
    {CurrentAddrs, _} = lists:unzip(connections(Kind, State)),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [libp2p_swarm:address(TID)],
    %% Remove the current addrs from all possible peer addresses
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(PeerAddrs), sets:from_list(ExcludedAddrs))),
    {noreply, assign_target(WorkderPid, TargetAddrs, State)};
handle_cast({assign_target, Kind=seed, WorkerPid}, State#state{}) ->
    {CurrentAddrs, _} = lists:unzip(connections(Kind, State)),
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(SeedAddrs), sets:from_list(CurrentAddrs))),
    {noreply, assign_target(WorkerPid, TargetAddrs, State)};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, PeerCount, SeedCount}, Msg, State=#state{}) ->
    [start_child(peerbook, State) || _ <- lists:seq(1, PeerCount)],
    [start_child(seed, State) || _ <- lists:seq(1, SeedCound)],
    {noreply, State;}
handle_info(drop_timeout, State=#state{monitors=[], drop_timeout=DropTimeOut, drop_timer=DropTimer}) ->
    erlang:cancel_timer(DropTimer),
    {noreply, State#state{drop_timer=schedule_drop_timer(DropTimeOut)}};
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.




%% Internal
%%

-spec schedule_drop_timer(pos_integer()) -> reference().
schedule_drop_timer(DropTimeOut) ->
    erlang:send_after(DropTimeOut, self(), drop_timeout).

connections(Kind, State#state{sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    Pids = [Pid || {_, Pid, _, _}  <- supervisor:which_children(WorkerSup)],
    [ {Addr, Pid} || {Knd, Addr, Pid} <- libp2p_group_gossip_worker:target_info(Pid), Knd == Kind].

assign_target(WorkerPid, TargetAddrs, State) ->
    SelectedAddr = case length(TargetAddrs) of
                       0 -> undefined;
                       _ -> lists:nth(rand:uniform(length(TargetAddrs)), TargetAddrs)
                   end,
    libp2p_group_gossip_worker:assign_target(WorkerPid, SelectedAddr),
    State.

start_child(Kind, #state{client_specs=ClientSpecs, sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    ChildSpec = #{ id => make_ref(),
                   start => {libp2p_group_gossip_workder, start_link, [Kind, ClientSpecs, Server, TID]},
                   resart => permanent
                 },
    {ok, _} = supervisor:start_child(WorkerSup, ChildSpec),
    ok.
