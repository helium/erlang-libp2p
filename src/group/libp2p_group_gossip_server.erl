-module(libp2p_group_gossip_server).

-behaviour(gen_server).

%% API
-export([start_link/2]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         peerbook_connections :: pos_integer(),
         seed_nodes :: [string()],
         client_spec :: libp2p_group:stream_client_spec(),
         workers=[] :: [worker()],
         drop_timeout :: pos_integer(),
         drop_timer :: reference()
       }).

-type worker() :: {Kind::atom(), Pid::pid(), MAddr::string() | undefined}.

-define(DEFAULT_PEERBOOK_CONNECTIONS, 5).
-define(DEFAULT_DROP_TIMEOUT, 5 * 60 * 1000).


%% gen_server
%%

start_link(Sup, TID) ->
    gen_server:start_link(?MODULE, [Sup, TID], []).

init([Sup, TID]) ->
    erlang:process_flag(trap_exit, true),
    %% TODO: Remove the assumption that this is _the_ group agent for
    %% the swarm. Perhaps by moving the creation into the swarm server
    %% instead of directly in the swarm_sup?
    libp2p_swarm_sup:register_group_agent(TID),
    Opts = libp2p_swarm:opts(TID, []),
    PeerBookCount = libp2p_group_gossip:get_opt(Opts, peerbook_connections, ?DEFAULT_PEERBOOK_CONNECTIONS),
    DropTimeOut = libp2p_group_gossip:get_opt(Opts, drop_timeout, ?DEFAULT_DROP_TIMEOUT),
    ClientSpec = libp2p_group_gossip:get_opt(Opts, stream_client, undefined),
    SeedNodes = libp2p_group_gossip:get_opt(Opts, seed_nodes, []),
    self() ! {start_workers, PeerBookCount, length(SeedNodes)},
    {ok, #state{sup=Sup, tid=TID, client_spec=ClientSpec,
                seed_nodes=SeedNodes, peerbook_connections=PeerBookCount,
                drop_timeout=DropTimeOut, drop_timer=schedule_drop_timer(DropTimeOut)}}.

handle_call(sessions, _From, State=#state{}) ->
    {reply, connections(all, State), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Kind=peerbook, WorkerPid}, State=#state{tid=TID}) ->
    PeerAddrs = libp2p_peerbook:keys(libp2p_swarm:peerbook(TID)),
    %% Get currently connected addresses
    {CurrentAddrs, _} = lists:unzip(connections(Kind, State)),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [libp2p_swarm:address(TID)],
    %% Remove the current addrs from all possible peer addresses
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(PeerAddrs), sets:from_list(ExcludedAddrs))),
    {noreply, assign_target(Kind, WorkerPid, TargetAddrs, State)};
handle_cast({request_target, Kind=seed, WorkerPid}, State=#state{seed_nodes=SeedAddrs}) ->
    {CurrentAddrs, _} = lists:unzip(connections(Kind, State)),
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(SeedAddrs), sets:from_list(CurrentAddrs))),
    {noreply, assign_target(Kind, WorkerPid, TargetAddrs, State)};
handle_cast({send, Bin}, State=#state{}) ->
    {_, Pids} = lists:unzip(connections(all, State)),
    lists:foreach(fun(Pid) ->
                          libp2p_group_worker:send(Pid, ignore, Bin)
                  end, Pids),
    {noreply, State};
handle_cast({send_result, _Ref, _Reason}, State=#state{}) ->
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, PeerCount, SeedCount}, State=#state{}) ->
    PeerBookWorkers = [start_child(peerbook, State) || _ <- lists:seq(1, PeerCount)],
    SeedWorkers = [start_child(seed, State) || _ <- lists:seq(1, SeedCount)],
    {noreply, State#state{workers=SeedWorkers ++ PeerBookWorkers}};
handle_info(drop_timeout, State=#state{drop_timeout=DropTimeOut, drop_timer=DropTimer, workers=Workers}) ->
    erlang:cancel_timer(DropTimer),
    case lists:filter(fun({_, _, MAddr}) -> MAddr =/= undefined end, Workers) of
        [] ->  {noreply, State#state{drop_timer=schedule_drop_timer(DropTimeOut)}};
        ConnectedWorkers ->
            {Kind, WorkerPid, MAddr} = lists:nth(rand:uniform(length(ConnectedWorkers)), ConnectedWorkers),
            lager:info("Timeout dropping 1 connection: ~p]", [MAddr]),
            {noreply, drop_target(Kind, WorkerPid, State#state{drop_timer=schedule_drop_timer(DropTimeOut)})}
    end;
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.




%% Internal
%%

-spec schedule_drop_timer(pos_integer()) -> reference().
schedule_drop_timer(DropTimeOut) ->
    erlang:send_after(DropTimeOut, self(), drop_timeout).

-spec connections(Kind::atom() | all, #state{}) -> [{MAddr::string(), Pid::pid()}].
connections(Kind, #state{workers=Workers}) ->
    lists:foldl(fun({_, _, undefined}, Acc) ->
                        Acc;
                    ({_, Pid, MAddr}, Acc) when Kind == all ->
                        [{MAddr, Pid} | Acc];
                    ({WorkerKind, Pid, MAddr}, Acc) when WorkerKind == Kind ->
                        [{MAddr, Pid} | Acc]
                end, [], Workers).

assign_target(Kind, WorkerPid, TargetAddrs, State=#state{workers=Workers}) ->
    SelectedAddr = case length(TargetAddrs) of
                       0 -> undefined;
                       _ -> mk_multiaddr(lists:nth(rand:uniform(length(TargetAddrs)), TargetAddrs))
                   end,
    libp2p_group_worker:assign_target(WorkerPid, SelectedAddr),
    NewWorkers = lists:keyreplace(WorkerPid, 2, Workers, {Kind, WorkerPid, SelectedAddr}),
    State#state{workers=NewWorkers}.

drop_target(Kind, WorkerPid, State=#state{workers=Workers}) ->
    libp2p_group_worker:assign_target(WorkerPid, undefined),
    NewWorkers = lists:keyreplace(WorkerPid, 2, Workers, {Kind, WorkerPid, undefined}),
    State#state{workers=NewWorkers}.

-spec start_child(atom(), #state{}) -> worker().
start_child(Kind, #state{tid=TID, client_spec=ClientSpec, sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    ChildSpec = #{ id => make_ref(),
                   start => {libp2p_group_worker, start_link, [Kind, ClientSpec, self(), TID]},
                   restart => permanent
                 },
    {ok, WorkerPid} = supervisor:start_child(WorkerSup, ChildSpec),
    {Kind, WorkerPid, undefined}.

mk_multiaddr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_multiaddr(Value) ->
    Value.
