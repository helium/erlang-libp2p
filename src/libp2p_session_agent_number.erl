-module(libp2p_session_agent_number).

-behavior(gen_server).

%% API
-export([check_connections/1]).

%% gen_server
-export([start_link/1, init/1, handle_info/2, handle_call/3, handle_cast/2]).


-record(state,
       { tid :: ets:tab(),
         peerbook_connections :: integer(),
         monitors=[] :: [{pid(), {reference(), atom(), [string()]}}]
       }).

-define(DEFAULT_PEERBOOK_CONNECTIONS, 5).


%% API
%%

-spec check_connections(pid()) -> ok.
check_connections(Pid) ->
    gen_server:cast(Pid, check_connections).


start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    Opts = libp2p_swarm:opts(TID, []),
    PeerBookCount = libp2p_config:get_opt(Opts, [?MODULE, peerbpook_connections],
                                          ?DEFAULT_PEERBOOK_CONNECTIONS),
    check_connections(self()),
    libp2p_peerbook:join_notify(libp2p_swarm:peerbook(TID), self()),
    {ok, #state{tid=TID, peerbook_connections=PeerBookCount}}.

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p~n", [Msg]),
    {reply, ok, State}.

handle_cast(check_connections, State=#state{}) ->
    {noreply, check_connections(peerbook, State)};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info({new_peers, []}, State=#state{}) ->
    {noreply, State};
handle_info({new_peers, _}, State=#state{}) ->
    {noreply, check_connections(peerbook, State)};
handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{}) ->
    NewState = remove_monitor(MonitorRef, Pid, State),
    {noreply, check_connections(peerbook, NewState)};
handle_info(Msg, _State) ->
    lager:warning("Unhandled message ~p", [Msg]).


%% Internal
%%

check_connections(Kind=peerbook, State=#state{tid=TID, peerbook_connections=PeerBookCount}) ->
    PeerAddrs = libp2p_peerbook:keys(libp2p_swarm:peerbook(TID)),
    %% Get currently connected addresses
    CurrentAddrs = connected_addrs(Kind, State),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [libp2p_swarm:address(TID)],
    %% Remove the current addrs from all possible peer addresses
    AvailableAddrs = sets:to_list(sets:subtract(sets:from_list(PeerAddrs), sets:from_list(ExcludedAddrs))),
    %% Shuffle the available addresses
    {_, ShuffledAddrs} = lists:unzip(lists:sort([ {rand:uniform(), Addr} || Addr <- AvailableAddrs])),
    case PeerBookCount - length(CurrentAddrs) of
        0 -> State;
        MissingCount ->
            lager:debug("Session agent trying to open ~p connections", [MissingCount]),
            %% Create connections for the missing number of connections
            mk_connections(libp2p_swarm:swarm(TID), Kind, ShuffledAddrs, MissingCount, State)
    end.

connected_addrs(Kind, #state{monitors=Monitors}) ->
    lists:flatten(lists:foldl(fun({_Pid, {_MonitorRef, StoredKind, Addrs}}, Acc) when StoredKind == Kind ->
                                      [Addrs | Acc];
                                 (_, Acc) -> Acc
                              end, [], Monitors)).

-spec add_monitor(atom(), libp2p_crypto:address(), pid(), #state{}) -> #state{}.
add_monitor(Kind, Addr, Pid, State=#state{monitors=Monitors}) ->
    Entry = case lists:keyfind(Pid, 1, Monitors) of
                false -> {Pid, {erlang:monitor(process, Pid), Kind, [Addr]}};
                {Pid, {MonitorRef, Kind, Addrs}} ->
                    {Pid, {MonitorRef, Kind, lists:merge(Addrs, [Addr])}}
            end,
    State#state{monitors=lists:keystore(Pid, 1, Monitors, Entry)}.

-spec remove_monitor(reference(), pid(), #state{}) -> #state{}.
remove_monitor(MonitorRef, Pid, State=#state{monitors=Monitors}) ->
    case lists:keytake(Pid, 1, Monitors) of
        false -> State;
        {value, {Pid, {MonitorRef, _, _}}, NewMonitors} ->
            State#state{monitors=NewMonitors}
    end.

-spec mk_connections(pid(), atom(), [libp2p_crypto:address()], non_neg_integer(), #state{}) -> #state{}.
mk_connections(_Swarm, _Kind, Addrs, Count, State)  when Addrs == [] orelse Count == 0 ->
    State;
mk_connections(Swarm, Kind, [Addr | Tail], Count, State) ->
    MAddr = mk_p2p_addr(Addr),
    case libp2p_swarm:connect(Swarm, MAddr) of
        {error, Reason} ->
            lager:info("Moving past ~p error: ~p", [MAddr, Reason]),
            mk_connections(Swarm, Kind, Tail, Count, State);
        {ok, SessionPid} ->
            mk_connections(Swarm, Kind, Tail, Count - 1, add_monitor(Kind, Addr, SessionPid, State))
    end.

-spec mk_p2p_addr(libp2p_crypto:address()) -> string().
mk_p2p_addr(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]).
