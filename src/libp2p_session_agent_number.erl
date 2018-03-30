-module(libp2p_session_agent_number).

-behavior(gen_server).


%% gen_server
-export([start_link/1, init/1, handle_info/2, handle_call/3, handle_cast/2]).


-type monitor_entry() :: {pid(), {reference(), atom(), binary()}}.

-record(state,
       { tid :: ets:tab(),
         peerbook_connections :: pos_integer(),
         drop_timeout :: pos_integer(),
         drop_timer :: reference(),
         monitors=[] :: [monitor_entry()]
       }).

-define(DEFAULT_PEERBOOK_CONNECTIONS, 5).
-define(DEFAULT_DROP_TIMEOUT, 10 * 60 * 60).

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    libp2p_swarm_sup:register_session_agent(TID),
    Opts = libp2p_swarm:opts(TID, []),
    PeerBookCount = libp2p_config:get_opt(Opts, [?MODULE, peerbook_connections],
                                          ?DEFAULT_PEERBOOK_CONNECTIONS),
    DropTimeOut = libp2p_config:get_opt(Opts, [?MODULE, drop_timeout], ?DEFAULT_DROP_TIMEOUT),
    self() ! init_connections,
    libp2p_peerbook:join_notify(libp2p_swarm:peerbook(TID), self()),
    {ok, (#state{tid=TID, peerbook_connections=PeerBookCount,
                 drop_timeout=DropTimeOut, drop_timer=schedule_drop_timer(DropTimeOut)})}.

handle_call(sessions, _From, State=#state{}) ->
    {reply, connections(peerbook, State), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p~n", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info(init_connections, State=#state{}) ->
    {noreply, check_connections(peerbook, State)};
handle_info({new_peers, []}, State=#state{}) ->
    {noreply, State};
handle_info({new_peers, _}, State=#state{}) ->
    {noreply, check_connections(peerbook, State)};
handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{}) ->
    NewState = remove_monitor(MonitorRef, Pid, State),
    {noreply, check_connections(peerbook, NewState)};
handle_info(drop_timeout, State=#state{monitors=[], drop_timeout=DropTimeOut, drop_timer=DropTimer}) ->
    erlang:cancel_timer(DropTimer),
    {noreply, State#state{drop_timer=schedule_drop_timer(DropTimeOut)}};
handle_info(drop_timeout, State=#state{monitors=Monitors, drop_timeout=DropTimeOut, drop_timer=DropTimer}) ->
    erlang:cancel_timer(DropTimer),
    DropEntry = lists:nth(rand:uniform(length(Monitors)), Monitors),
    lager:info("Timeout dropping connected address ~p]", [mk_p2p_addr(monitor_addr(DropEntry))]),
    NewMonitors = lists:delete(DropEntry, Monitors),
    {noreply, State#state{monitors=NewMonitors, drop_timer=schedule_drop_timer(DropTimeOut)}};
handle_info(Msg, _State) ->
    lager:warning("Unhandled message ~p", [Msg]).


%% Internal
%%

-spec schedule_drop_timer(pos_integer()) -> reference().
schedule_drop_timer(DropTimeOut) ->
    erlang:send_after(DropTimeOut, self(), drop_timeout).

check_connections(Kind=peerbook, State=#state{tid=TID, peerbook_connections=PeerBookCount}) ->
    PeerAddrs = libp2p_peerbook:keys(libp2p_swarm:peerbook(TID)),
    %% Get currently connected addresses
    {CurrentAddrs, _} = lists:unzip(connections(Kind, State)),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [libp2p_swarm:address(TID)],
    %% Remove the current addrs from all possible peer addresses
    AvailableAddrs = sets:to_list(sets:subtract(sets:from_list(PeerAddrs), sets:from_list(ExcludedAddrs))),
    %% Shuffle the available addresses
    {_, ShuffledAddrs} = lists:unzip(lists:sort([ {rand:uniform(), Addr} || Addr <- AvailableAddrs])),
    case PeerBookCount - length(CurrentAddrs) of
        0 -> State;
        MissingCount ->
            lager:debug("Session agent trying to open ~p connections from ~p available",
                        [MissingCount, length(ShuffledAddrs)]),
            %% Create connections for the missing number of connections
            mk_connections(libp2p_swarm:swarm(TID), Kind, ShuffledAddrs, MissingCount, State)
    end.

-spec connections(atom(), #state{}) -> [{pid(), libp2p_crypto:address()}].
connections(Kind, #state{monitors=Monitors}) ->
    lists:foldl(fun({Pid, {_, StoredKind, Addr}}, Acc) when StoredKind == Kind ->
                        [{Addr, Pid} | Acc];
                   (_, Acc) -> Acc
                end, [], Monitors).

-spec add_monitor(atom(), libp2p_crypto:address(), pid(), #state{}) -> #state{}.
add_monitor(Kind, Addr, Pid, State=#state{monitors=Monitors}) ->
    Entry = case lists:keyfind(Pid, 1, Monitors) of
                false -> {Pid, {erlang:monitor(process, Pid), Kind, Addr}};
                {Pid, {MonitorRef, Kind, _}} ->
                    %% We should not end up in a state where the same
                    %% PID is attached to a different crypto address,
                    %% but if it does we
                    {Pid, {MonitorRef, Kind, Addr}}
            end,
    State#state{monitors=lists:keystore(Pid, 1, Monitors, Entry)}.

-spec remove_monitor(reference(), pid(), #state{}) -> #state{}.
remove_monitor(MonitorRef, Pid, State=#state{monitors=Monitors}) ->
    case lists:keytake(Pid, 1, Monitors) of
        false -> State;
        {value, {Pid, {MonitorRef, _, _}}, NewMonitors} ->
            State#state{monitors=NewMonitors}
    end.

-spec monitor_addr(monitor_entry()) -> binary().
monitor_addr({_Pid, {_Ref, _Kind, Addr}}) ->
    Addr.

-spec mk_connections(pid(), atom(), [libp2p_crypto:address()], non_neg_integer(), #state{}) -> #state{}.
mk_connections(_Swarm, _Kind, Addrs, Count, State)  when Addrs == [] orelse Count == 0 ->
    State;
mk_connections(Swarm, Kind, [Addr | Tail], Count, State) ->
    MAddr = mk_p2p_addr(Addr),
    case libp2p_swarm:connect(Swarm, MAddr) of
        {error, Reason} ->
            lager:debug("Moving past ~p error: ~p", [MAddr, Reason]),
            mk_connections(Swarm, Kind, Tail, Count, State);
        {ok, SessionPid} ->
            mk_connections(Swarm, Kind, Tail, Count - 1, add_monitor(Kind, Addr, SessionPid, State))
    end.

-spec mk_p2p_addr(libp2p_crypto:address()) -> string().
mk_p2p_addr(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]).
