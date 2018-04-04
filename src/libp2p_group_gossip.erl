-module(libp2p_group_gossip).

-behavior(gen_server).

% API
-export([sessions/1]).

%% gen_server
-export([start_link/1, init/1, handle_info/2, handle_call/3, handle_cast/2]).

-type opt() :: {peerbook_connections, pos_integer()}
             | {drop_timeout, pos_integer()}
             | {stream_clients, [client_spec()]}
             | {seed_nodes, [seed_node()]}.

-type client_spec() :: {Path::string(), {Module::atom(), Args::[any()]}}.
-type seed_node() :: {node, [ListenAddr::string()]}.

-export_type([opt/0]).

-type monitor_addr() :: libp2p_crypto:address() | string().
-type monitor_entry() :: {pid(), reference(), [{atom(), monitor_addr()}]}.

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
%

-spec sessions(pid()) -> [{libp2p_crypto:address(), libp2p_session:pid()}].
sessions(Pid) ->
    gen_server:call(Pid, sessions).


-define(DEFAULT_PEERBOOK_CONNECTIONS, 5).
-define(DEFAULT_DROP_TIMEOUT, 10 * 60 * 60).

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_group_agent(TID),
    Opts = libp2p_swarm:opts(TID, []),
    PeerBookCount = libp2p_config:get_opt(Opts, [?MODULE, peerbook_connections],
                                          ?DEFAULT_PEERBOOK_CONNECTIONS),
    DropTimeOut = libp2p_config:get_opt(Opts, [?MODULE, drop_timeout], ?DEFAULT_DROP_TIMEOUT),
    ClientSpecs = libp2p_config:get_opt(Opts, [?MODULE, stream_clients], []),
    SeedNodes = libp2p_config:get_opt(Opts, [?MODULE, seed_nodes], []),
    self() ! {check_connections, seed},
    self() ! {check_connections, peerbook},
    libp2p_peerbook:join_notify(libp2p_swarm:peerbook(TID), self()),
    {ok, #state{tid=TID, peerbook_connections=PeerBookCount,
                drop_timeout=DropTimeOut, drop_timer=schedule_drop_timer(DropTimeOut),
                seed_nodes=SeedNodes, client_specs=ClientSpecs}}.

handle_call(sessions, _From, State=#state{}) ->
    {reply, connections(any, State), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({check_connections, Kind}, State=#state{}) ->
    {noreply, check_connections(Kind, State)};
handle_info({register_connection, Kind, Addr, SessionPid}, State=#state{client_specs=ClientSpecs}) ->
    lists:foreach(fun({Path, {M, A}}) ->
                          libp2p_session:start_client_framed_stream(Path, SessionPid, M, A)
                  end, ClientSpecs),
    {noreply, add_monitor(Kind, Addr, SessionPid, State)};
handle_info({new_peers, []}, State=#state{}) ->
    {noreply, State};
handle_info({new_peers, _}, State=#state{}) ->
    {noreply, check_connections(peerbook, State)};
handle_info({'DOWN', _MonitorRef, process, Pid, _}, State=#state{}) ->
    NewState = remove_monitor(Pid, State),
    {noreply, check_connections(peerbook, NewState)};
handle_info(drop_timeout, State=#state{monitors=[], drop_timeout=DropTimeOut, drop_timer=DropTimer}) ->
    erlang:cancel_timer(DropTimer),
    {noreply, State#state{drop_timer=schedule_drop_timer(DropTimeOut)}};
handle_info(drop_timeout, State=#state{monitors=Monitors, drop_timeout=DropTimeOut, drop_timer=DropTimer}) ->
    erlang:cancel_timer(DropTimer),
    DropEntry = lists:nth(rand:uniform(length(Monitors)), Monitors),
    lager:info("Timeout dropping 1 connection: ~p]", [monitor_addrs(DropEntry)]),
    NewMonitors = lists:delete(DropEntry, Monitors),
    {noreply, State#state{monitors=NewMonitors, drop_timer=schedule_drop_timer(DropTimeOut)}};
handle_info(Msg, _State) ->
    lager:warning("Unhandled message ~p", [Msg]).


%% Internal
%%

-spec schedule_drop_timer(pos_integer()) -> reference().
schedule_drop_timer(DropTimeOut) ->
    erlang:send_after(DropTimeOut, self(), drop_timeout).

-spec check_connections(atom(), #state{}) -> #state{}.
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
        %% No missing connections
        0 -> ok;
        %% No targets to try to connect to
        _MissingCount when length(ShuffledAddrs) == 0 -> ok;
        %% Go try to connect one with the available shuffled addresses
        _ ->
            %% Create connections for the missinge number of connections
            spawn_mk_connection(self(), TID, Kind, ShuffledAddrs)
    end,
    State;
check_connections(Kind=seed, State=#state{tid=TID, seed_nodes=SeedAddrs}) ->
    {CurrentAddrs, _} = lists:unzip(connections(Kind, State)),
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(SeedAddrs), sets:from_list(CurrentAddrs))),
    case length(TargetAddrs) of
        0 -> ok;
        _ ->
            spawn_mk_connection(self(), TID, Kind, TargetAddrs)
    end,
    State.

spawn_mk_connection(Parent, TID, Kind, Addrs) ->
    lager:debug("Session agent trying to open a ~p connection from ~p available",
                [Kind, length(Addrs)]),
    spawn(fun() ->
                  mk_connection(Parent, TID, Kind, Addrs)
          end).

-spec connections(atom(), #state{}) -> [{pid(), monitor_addr()}].
connections(Kind, #state{monitors=Monitors}) ->
    Result = lists:foldl(fun({_Pid, _MonitorRef, Entries}, Acc) when Kind == any ->
                                 [Entries | Acc];
                            ({Pid, _MonitorRef, Entries}, Acc) ->
                                 case lists:keyfind(Kind, 1, Entries) of
                                     false -> Acc;
                                     {Kind, Addr} -> [{Addr, Pid} | Acc]
                                 end;
                            (_, Acc) -> Acc
                         end, [], Monitors),
    lists:flatten(Result).

-spec add_monitor(atom(), monitor_addr(), pid(), #state{}) -> #state{}.
add_monitor(Kind, Addr, Pid, State=#state{monitors=Monitors}) ->
    Entry = case lists:keyfind(Pid, 1, Monitors) of
                false -> {Pid, erlang:monitor(process, Pid), [{Kind, Addr}]};
                {Pid, MonitorRef, Entries} ->
                    case lists:keyfind(Kind, 1, Entries) of
                        false -> {Pid, MonitorRef, lists:keystore(Kind, 1, Entries, {Kind, Addr})};
                        _ -> {Pid, Entries}
                    end
            end,
    State#state{monitors=lists:keystore(Pid, 1, Monitors, Entry)}.

-spec remove_monitor(pid(), #state{}) -> #state{}.
remove_monitor(Pid, State=#state{monitors=Monitors}) ->
    case lists:keytake(Pid, 1, Monitors) of
        false -> State;
        {value, {Pid, _MonitorRef, _Entries}, NewMonitors} ->
            State#state{monitors=NewMonitors}
    end.

-spec monitor_addrs(monitor_entry()) -> [monitor_addr()].
monitor_addrs({_Pid, _MonitorRef, Entries}) ->
    Entries.

-spec mk_connection(pid(), ets:tab(), atom(), [monitor_addr()])
                   -> check_connections | {register_connection, atom(), monitor_addr(), libp2p_session:pid()}.
mk_connection(Parent, _TID, Kind, Addrs)  when Addrs == [] ->
    erlang:send_after(1000, Parent, {check_connections, Kind});
mk_connection(Parent, TID, Kind, [Addr | Tail]) ->
    MAddr = mk_p2p_addr(Addr),
    case libp2p_transport:connect_to(MAddr, [], 5000, TID) of
        {error, Reason} ->
            lager:debug("Moving past ~p error: ~p", [MAddr, Reason]),
            mk_connection(Parent, TID, Kind, Tail);
        {ok, ConnAddr, SessionPid} ->
            libp2p_swarm:register_session(libp2p_swarm:swarm(TID), ConnAddr, SessionPid),
            Parent ! {register_connection, Kind, Addr, SessionPid}
    end.

-spec mk_p2p_addr(monitor_addr()) -> string().
mk_p2p_addr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_p2p_addr(MAddr) when is_list(MAddr) ->
    MAddr.
