-module(libp2p_group_gossip_server).

-behaviour(gen_server).
-behavior(libp2p_gossip_stream).

-include("gossip.hrl").
-include_lib("kernel/include/inet.hrl"). %% for DNS lookup

%% API
-export([start_link/2]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% libp2p_gossip_stream
-export([accept_stream/4, handle_identify/4, handle_data/7]).

-record(worker,
       { target :: binary() | string() | undefined,
         kind :: libp2p_group_gossip:connection_kind(),
         pid :: pid() | self,
         ref :: reference()
       }).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         peerbook_connections :: pos_integer(),
         seednode_connections :: pos_integer(),
         max_inbound_connections :: non_neg_integer(),
         seed_nodes :: [string()],
         workers_to_add=[] :: [{libp2p_group_gossip:connection_kind(), pid()}],
         workers=#{} :: #{atom() => #{reference() => #worker{}}},
         targets=#{} :: #{string() => {atom(), reference()}},
         monitors=#{} :: #{reference() => {atom(), pid(), reference()}},
         handlers=#{} :: #{string() => libp2p_group_gossip:handler()},
         drop_timeout :: pos_integer(),
         drop_timer :: reference(),
         supported_paths :: [string()],
         bloom :: bloom_nif:bloom(),
         sidejob_sup :: atom()
       }).

-define(DEFAULT_PEERBOOK_CONNECTIONS, 5).
-define(DEFAULT_SEEDNODE_CONNECTIONS, 2).
-define(DEFAULT_MAX_INBOUND_CONNECTIONS, 10).
-define(DEFAULT_DROP_TIMEOUT, 5 * 60 * 1000).
-define(GROUP_ID, "gossip").
-define(DNS_RETRIES, 3).
-define(DNS_TIMEOUT, 2000). % millis
-define(DNS_SLEEP, 100). % millis
-define(DEFAULT_SEED_DNS_PORTS, [2154, 443]).

%% API
%%

start_link(Sup, TID) ->
    gen_server:start_link(reg_name(TID), ?MODULE, [Sup, TID], [{hibernate_after, 5000}]).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

%% libp2p_gossip_stream
%%

handle_data(_Pid, StreamPid, Kind, Peer, Key, TID, {Path, Bin}) ->
    %% experimentally move decoding out to the caller
    ListOrData =
        case Key of
            "peer" ->
                {Path, libp2p_peer:decode_list(Bin)};
            _ ->
                {Path, Bin}
        end,
    lager:info("gossip data from peer ~p ~p", [Kind, Peer]),
    %% check the cache, see the lookup_handler function for details
    case lookup_handler(TID, Key) of
        error ->
            ok;
        {ok, M, S} ->
            %% Catch the callback response. This avoids a crash in the
            %% handler taking down the gossip worker itself.
            try M:handle_gossip_data(StreamPid, Kind, Peer, ListOrData, S) of
                {reply, Reply} ->
                    %% handler wants to reply
                    %% NOTE - This routes direct via libp2p_framed_stream:send/2 and not via the group worker
                    %%        As such we need to encode at this point, and send raw..no encoding actions
                    case (catch libp2p_gossip_stream:encode(Key, Reply, Path)) of
                        {'EXIT', Error} ->
                            lager:warning("Error encoding gossip data ~p", [Error]);
                        ReplyMsg ->
                            {reply, ReplyMsg}
                    end;
                _ ->
                    ok
            catch _:_ ->
                    ok
            end
    end.

accept_stream(Pid, SessionPid, StreamPid, Path) ->
    Ref = erlang:monitor(process, Pid),
    gen_server:cast(Pid, {accept_stream, SessionPid, Ref, StreamPid, Path}),
    Ref.

handle_identify(Pid, StreamPid, Path, Identify) ->
    gen_server:call(Pid, {handle_identify, StreamPid, Path, Identify}, 15000).

%% gen_server
%%

init([Sup, TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_gossip_group(TID),
    Opts = libp2p_swarm:opts(TID),
    SideJobRegName = list_to_atom(atom_to_list(libp2p_swarm_sidejob_sup) ++ "_" ++ atom_to_list(TID)),
    PeerBookCount = get_opt(Opts, peerbook_connections, ?DEFAULT_PEERBOOK_CONNECTIONS),
    SeedNodes = get_opt(Opts, seed_nodes, []),
    SeedNodeCount =
        case application:get_env(libp2p, seed_node, false) of
            false ->
                get_opt(Opts, seednode_connections, ?DEFAULT_SEEDNODE_CONNECTIONS);
            true ->
                length(maybe_lookup_seed_in_dns(SeedNodes)) - 1
        end,
    InboundCount = get_opt(Opts, inbound_connections, ?DEFAULT_MAX_INBOUND_CONNECTIONS),
    DropTimeOut = get_opt(Opts, drop_timeout, ?DEFAULT_DROP_TIMEOUT),
    SupportedPaths = get_opt(Opts, supported_gossip_paths, ?SUPPORTED_GOSSIP_PATHS),
    lager:debug("Supported gossip paths: ~p:", [SupportedPaths]),

    {ok, Bloom} = bloom:new_forgetful_optimal(1000, 3, 800, 1.0e-3), 

    ets:insert(TID, {gossip_bloom, Bloom}),

    self() ! {start_workers, Sup},
    {ok, update_metadata(#state{sup=Sup, tid=TID,
                                seed_nodes=SeedNodes,
                                max_inbound_connections=InboundCount,
                                peerbook_connections=PeerBookCount,
                                seednode_connections=SeedNodeCount,
                                drop_timeout=DropTimeOut,
                                drop_timer=schedule_drop_timer(DropTimeOut),
                                bloom=Bloom,
                                sidejob_sup = SideJobRegName,
                                supported_paths=SupportedPaths})}.

handle_call({connected_addrs, Kind}, _From, State=#state{workers=Workers}) ->
    Addrs = connection_addrs(Kind, Workers),
    {reply, Addrs, State};
handle_call({connected_pids, Kind}, _From, State) ->
    Pids = connection_pids(Kind, State#state.workers),
    {reply, Pids, State};

handle_call({remove_handler, Key}, _From, State=#state{handlers=Handlers, tid=TID}) ->
    NewHandlers = maps:remove(Key, Handlers),
    ets:insert(TID, {gossip_handlers, NewHandlers}),
    {reply, ok, State#state{handlers=NewHandlers}};

handle_call({handle_identify, StreamPid, Path, {ok, Identify}},
            From, State) ->
    Target = libp2p_identify:pubkey_bin(Identify),
    %% Check if we already have a worker for this target
    case lookup_worker_by_target(Target, State) of
        %% If not, we we check if we can accept a random inbound
        %% connection and start a worker for the inbound stream if ok
        false ->
            case count_workers(inbound, State) > State#state.max_inbound_connections of
                true ->
                    lager:debug("Too many inbound workers: ~p",
                                [State#state.max_inbound_connections]),
                    {reply, {error, too_many}, State};
                false ->
                    start_inbound_worker(From, Target, StreamPid, Path, State)
            end;
        %% There's an existing worker for the given address, re-assign
        %% the worker the new stream.
        #worker{pid=WorkerPid}=Worker ->
            case is_process_alive(WorkerPid) of
                true ->
                    libp2p_group_worker:assign_stream(WorkerPid, StreamPid, Path),
                    {reply, ok, State};
                false ->
                    start_inbound_worker(From, Target, StreamPid, Path, remove_worker(Worker, State))
            end
    end;

handle_call({handle_data, Key}, _From, State=#state{}) ->
    %% Incoming message from a gossip stream for a given key
    %% for performance reasons, and for backpressure, just return
    %% the module and state
    case maps:find(Key, State#state.handlers) of
        error -> {reply, error, State};
        {ok, {M, S}} ->
            {reply, {ok, M, S}, State}
    end;

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.


handle_cast({accept_stream, _Session, ReplyRef, StreamPid, _Path}, State=#state{workers=[]}) ->
    StreamPid ! {ReplyRef, {error, not_ready}},
    {noreply, State};
handle_cast({accept_stream, Session, ReplyRef, StreamPid, Path}, State=#state{}) ->
    case count_workers(inbound, State) > State#state.max_inbound_connections of
        true ->
            StreamPid ! {ReplyRef, {error, too_many}};
        false ->
            libp2p_session:identify(Session, self(), {ReplyRef, StreamPid, Path})
    end,
    {noreply, State};

handle_cast({add_handler, Key, Handler}, State=#state{handlers=Handlers, tid=TID}) ->
    NewHandlers = maps:put(Key, Handler, Handlers),
    ets:insert(TID, {gossip_handlers, NewHandlers}),
    {noreply, State#state{handlers=NewHandlers}};
handle_cast({request_target, inbound, WorkerPid, Ref}, State=#state{}) ->
    {noreply, stop_inbound_worker(Ref, WorkerPid, State)};
handle_cast({request_target, peerbook, WorkerPid, Ref}, State=#state{tid=TID}) ->
    LocalAddr = libp2p_swarm:pubkey_bin(TID),
    PeerList = case libp2p_swarm:peerbook(TID) of
                   false ->
                       [];
                   Peerbook ->

                       WorkerAddrs = get_addrs(State#state.workers),
                       try
                           Pred = application:get_env(libp2p, random_peer_pred, fun(_) -> true end),
                           Ct = application:get_env(libp2p, random_peer_tries, 100),
                           case libp2p_peerbook:random(Peerbook, [LocalAddr|WorkerAddrs], Pred, Ct) of
                               {Addr, _} ->
                                   [Addr];
                               false ->
                                   %% if we can't find a peer with the predicate, relax it
                                   case libp2p_peerbook:random(Peerbook, [LocalAddr|WorkerAddrs]) of
                                       {Addr, _} ->
                                           [Addr];
                                       false ->
                                           lager:debug("cannot get target as no peers or already connected to all peers",[]),
                                           []
                                   end
                           end
                       catch _:_ ->
                               []
                       end
               end,
    {noreply, assign_target(WorkerPid, Ref, PeerList, State)};
handle_cast({request_target, seed, WorkerPid, Ref}, State=#state{tid=TID, seed_nodes=SeedAddrs, workers=Workers}) ->
    CurrentAddrs = connection_addrs(seed, Workers),
    LocalAddr = libp2p_swarm:p2p_address(TID),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [LocalAddr],
    BaseAddrs = sets:to_list(sets:subtract(sets:from_list(SeedAddrs),
                                             sets:from_list(ExcludedAddrs))),
    TargetAddrs = maybe_lookup_seed_in_dns(BaseAddrs),
    {noreply, assign_target(WorkerPid, Ref, TargetAddrs, State)};
handle_cast({send, Key, Data}, State) ->
    %% assume all gossip peers
    handle_cast({send, all, Key, Data}, State);
handle_cast({send, all, Key, Fun}, State=#state{workers=Workers}) when is_function(Fun, 1) ->
    %% use a fun to generate the send data for each gossip peer
    %% this can be helpful to send a unique random subset of data to each peer
    %% find out what kind of connection we are dealing with and pass that type to the fun
    spawn(fun() ->
                  [ libp2p_group_worker:send(Pid, Key, Fun(seed), true) || Pid <- connection_pids(seed, Workers) ],
                  [ libp2p_group_worker:send(Pid, Key, Fun(peerbook), true) || Pid <- connection_pids(peerbook, Workers) ],
                  [ libp2p_group_worker:send(Pid, Key, Fun(inbound), true) || Pid <- connection_pids(inbound, Workers) ]
          end),
    {noreply, State};
handle_cast({send, Kind, Key, Fun}, State=#state{}) when is_function(Fun, 1) ->
    %% use a fun to generate the send data for each gossip peer
    %% this can be helpful to send a unique random subset of data to each peer
    Pids = connection_pids(Kind, State#state.workers),
    lists:foreach(fun(Pid) ->
                          Data = Fun(Kind),
                          %% Catch errors encoding the given arguments to avoid a bad key or
                          %% value taking down the gossip server
                          libp2p_group_worker:send(Pid, Key, Data, true)
                  end, Pids),
    {noreply, State};

handle_cast({send, Kind, Key, Data}, State=#state{bloom=Bloom, workers=Workers}) ->
    case bloom:check(Bloom, {out, Data}) of
        true ->
            ok;
        false ->
            bloom:set(Bloom, {out, Data}),
            spawn(fun() ->
                          lists:foreach(fun(Pid) ->
                                                %% TODO we could check the connections's Address here for
                                                %% if we received this data from that address and avoid
                                                %% bouncing the gossip data back
                                                libp2p_group_worker:send(Pid, Key, Data, true)
                                        end, connection_pids(Kind, Workers))
                  end)
    end,
    {noreply, State};
handle_cast({send_ready, _Target, _Ref, false}, State=#state{}) ->
    %% Ignore any not ready messages from group workers. The gossip
    %% server only reacts to ready messages by sending initial
    %% gossip_data.
    {noreply, State};
handle_cast({send_ready, Target, _Ref, _Ready}, State=#state{handlers=Handlers}) ->
    case lookup_worker_by_target(Target, State) of
        #worker{pid=WorkerPid} ->
                maps:fold(fun(Key, {M, S}, Acc) ->
                                case (catch M:init_gossip_data(S)) of
                                    {'EXIT', Reason} ->
                                        lager:warning("gossip handler ~s failed to init with error ~p", [M, Reason]),
                                        Acc;
                                    ok ->
                                        Acc;
                                    {send, Msg} ->
                                        libp2p_group_worker:send(WorkerPid, Key, Msg, true),
                                        Acc
                                end
                        end, none, Handlers),
            {noreply, State};
        _ ->
            {noreply, State}
    end;
handle_cast({send_result, _Ref, _Reason}, State=#state{}) ->
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


handle_info({started_inbound_worker, {ok, Worker}}, State) ->
    {noreply, add_worker(Worker, State)};
handle_info({start_workers, Sup},
            State0 = #state{tid=TID, seednode_connections=SeedCount,
                            peerbook_connections=PeerCount,
                            bloom=Bloom,
                            supported_paths = SupportedPaths}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    State = State0#state{sup = WorkerSup},
    PeerBookWorkers =
        lists:foldl(
          fun(_, Acc) ->
                  case start_worker(peerbook, State) of
                      {ok, Worker} ->
                          Acc#{Worker#worker.ref => Worker};
                      _ -> Acc
                  end
          end,
          #{},
          lists:seq(1, PeerCount)),
    SeedWorkers =
        lists:foldl(
          fun(_, Acc) ->
                  case start_worker(seed, State) of
                      {ok, Worker} ->
                          Acc#{Worker#worker.ref => Worker};
                      _ -> Acc
                  end
          end,
          #{},
          lists:seq(1, SeedCount)),

    GossipAddFun = fun(Path) ->
                           libp2p_swarm:add_stream_handler(TID, Path,
                                                        {libp2p_gossip_stream, server, [Path, ?MODULE, self(), TID, Bloom]})
                   end,
    lists:foreach(GossipAddFun, SupportedPaths),
    {noreply, State#state{workers=#{seed => SeedWorkers, peerbook => PeerBookWorkers}}};
handle_info(drop_timeout, State=#state{drop_timeout=DropTimeOut, drop_timer=DropTimer,
                                       workers=Workers}) ->
    erlang:cancel_timer(DropTimer),
    case get_workers(Workers) of
        [] ->  {noreply, State#state{drop_timer=schedule_drop_timer(DropTimeOut)}};
        ConnectedWorkers ->
            Worker = lists:nth(rand:uniform(length(ConnectedWorkers)), ConnectedWorkers),
            lager:debug("Timeout dropping 1 connection: ~p]", [Worker#worker.target]),
            {noreply, drop_target(Worker, State#state{drop_timer=schedule_drop_timer(DropTimeOut)})}
    end;
handle_info({handle_identify, {ReplyRef, StreamPid, _Path}, {error, Error}}, State=#state{}) ->
    StreamPid ! {ReplyRef, {error, Error}},
    {noreply, State};
handle_info({handle_identify, {ReplyRef, StreamPid, Path}, {ok, Identify}}, State=#state{}) ->
    Target = libp2p_identify:pubkey_bin(Identify),
    %% Check if we already have a worker for this target
    case lookup_worker_by_target(Target, State) of
        %% If not, we we check if we can accept a random inbound
        %% connection and start a worker for the inbound stream if ok
        false ->
            lager:debug("received identity for non existing target ~p.  Stream: ~p",[Target, StreamPid]),
            case count_workers(inbound, State) > State#state.max_inbound_connections of
                true ->
                    lager:debug("Too many inbound workers: ~p",
                                [State#state.max_inbound_connections]),
                    StreamPid ! {ReplyRef, {error, too_many}},
                    {noreply, State};
                false ->
                    start_inbound_worker({raw, StreamPid, ReplyRef}, Target, StreamPid, Path, State)
            end;
        %% There's an existing worker for the given address, re-assign
        %% the worker the new stream.
        #worker{pid=Worker} ->
            lager:debug("received identity for existing target ~p.  Stream: ~p",[Target, StreamPid]),
            libp2p_group_worker:assign_stream(Worker, StreamPid, Path),
            StreamPid ! {ReplyRef, ok},
            {noreply, State}
    end;
handle_info({'DOWN', Ref, process, Pid, Reason}, State = #state{monitors=Monitors}) ->
    case maps:get(Ref, Monitors, undefined) of
        {_Kind, Pid, WorkerRef} ->
            case Reason == normal orelse Reason == shutdown of
                true ->
                    ok;
                false ->
                    %lager:info("worker ~p exited with reason ~p", [Pid, Reason])
                    ok
            end,
            case lookup_worker(WorkerRef, State) of
                Worker = #worker{} ->
                    {noreply, remove_worker(Worker, State#state{monitors=maps:remove(Ref, Monitors)})};
                not_found ->
                    {noreply, State#state{monitors=maps:remove(Ref, Monitors)}}
            end;
        undefined ->
            {noreply, State}
    end;
handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{tid=TID, supported_paths = SupportedPaths}) ->
    GossipAddFun = fun(Path) ->
                        libp2p_swarm:remove_stream_handler(TID, Path)
                   end,
    lists:foreach(GossipAddFun, SupportedPaths),
    ok.

%% Internal
%%

-spec schedule_drop_timer(pos_integer()) -> reference().
schedule_drop_timer(DropTimeOut) ->
    erlang:send_after(DropTimeOut, self(), drop_timeout).


-spec connection_pids(libp2p_group_gossip:connection_kind() | all, #{atom() => #{reference() => #worker{}}})
                 -> [Pid::pid()].
connection_pids(all, Workers) ->
    maps:fold(
      fun(Kind, _, Acc) ->
              Conns = connection_pids(Kind, Workers),
              lists:append(Conns, Acc)
      end,
      [],
      Workers);
connection_pids(Kind, Workers) ->
    KindMap = maps:get(Kind, Workers, #{}),
    [ Pid || #worker{target = Target, pid = Pid} <- maps:values(KindMap), Target /= undefined ].


-spec connection_addrs(libp2p_group_gossip:connection_kind() | all, #{atom() => #{reference() => #worker{}}})
                 -> [MAddr::string()].
connection_addrs(all, Workers) ->
    maps:fold(
      fun(Kind, _, Acc) ->
              Conns = connection_addrs(Kind, Workers),
              lists:append(Conns, Acc)
      end,
      [],
      Workers);
connection_addrs(Kind, Workers) ->
    KindMap = maps:get(Kind, Workers, #{}),
    [ Target || #worker{target = Target} <- maps:values(KindMap), Target /= undefined ].


assign_target(WorkerPid, WorkerRef, TargetAddrs, State=#state{workers=Workers, supported_paths = SupportedPaths, tid=TID, bloom=Bloom}) ->
    case length(TargetAddrs) of
        0 ->
            %% the ref is stable across restarts, so use that as the lookup key
            case lookup_worker(WorkerRef, State) of
                Worker=#worker{kind=seed, target=SelectedAddr, pid=StoredWorkerPid} when SelectedAddr /= undefined ->
                    %% don't give up on the seed nodes in case we're entirely offline
                    %% we need at least one connection to bootstrap the swarm
                    ClientSpec = {SupportedPaths, {libp2p_gossip_stream, [?MODULE, self(), TID, Bloom, seed, SelectedAddr]}},
                    libp2p_group_worker:assign_target(WorkerPid, {SelectedAddr, ClientSpec}),
                    %% check if this worker got restarted
                    case WorkerPid /= StoredWorkerPid of
                        true ->
                            SeedMap = maps:get(seed, Workers),
                            NewWorkers = Workers#{seed => SeedMap#{WorkerRef => Worker#worker{pid=WorkerPid}}},
                            State#state{workers=NewWorkers};
                        false ->
                            State
                    end;
                _ ->
                    State
            end;
        _ ->
            %% the ref is stable across restarts, so use that as the lookup key
            case lookup_worker(WorkerRef, State) of
                Worker=#worker{kind=Kind} ->
                    SelectedAddr = mk_multiaddr(choose_random_element(TargetAddrs)),
                    ClientSpec = {SupportedPaths, {libp2p_gossip_stream, [?MODULE, self(), TID, Bloom, Kind, SelectedAddr]}},
                    libp2p_group_worker:assign_target(WorkerPid, {SelectedAddr, ClientSpec}),
                    %% since we have to update the worker here anyway, update the worker pid as well
                    %% so we handle restarts smoothly
                    NewWorker = Worker#worker{target=SelectedAddr, pid=WorkerPid},
                    add_worker(NewWorker, State);
                _ ->
                    State
            end
    end.

maybe_lookup_seed_in_dns(TargetAddrs) ->
    case application:get_env(libp2p, use_dns_for_seeds, false) of
        false ->
            TargetAddrs;
        true ->
            case get(dns_seeds) of
                undefined ->
                    Res = lookup_seed_from_dns(TargetAddrs),
                    put(dns_seeds, {erlang:system_time(seconds), Res}),
                    Res;
                {Time, Value} ->
                    case (erlang:system_time(seconds) - Time) > 60 of
                        true ->
                            erase(dns_seeds),
                            maybe_lookup_seed_in_dns(TargetAddrs);
                        false ->
                            Value
                    end
            end
    end.

choose_random_element([E]) -> E;
choose_random_element(L) when is_list(L) ->
    lists:nth(rand:uniform(length(L)), L).

%% We will (try to) lookup seed IPs from a (pool of) DNS cname, and fall back to
%% using the static seed list
lookup_seed_from_dns(TargetAddrs) ->
    case application:get_env(libp2p, seed_dns_cname, undefined) of
        undefined ->
            lager:error("Configured to use DNS to lookup seed node IP, but the cname is undefined", []),
            TargetAddrs;
        BaseCName ->
            %% to help migitate possible eclipse attacks we will blend the DNS results
            %% with the static list of seed nodes
            collect_dns_records(BaseCName) ++ TargetAddrs
    end.

collect_dns_records(Base) ->
    AdditionalNames = generate_seed_pool_names(application:get_env(libp2p, seed_config_dns_name, undefined)),
    DNSNames = maybe_make_seed_pool_names(Base, AdditionalNames),
    lists:foldl(fun do_dns_lookups/2, [], DNSNames).

generate_seed_pool_names(undefined) -> [];
generate_seed_pool_names(ConfigDnsName) ->
    case inet_res:lookup(ConfigDnsName, in, txt) of
        [] -> []; %% there was an error of some kind, return empty list
        [[PoolSizeStr]] ->
            PoolStart = $1, %% ASCII "1"
            %% increment PoolStart so we start pool names using ASCII "2"
            %%
            %% end at ASCII "1" + pool size (as an integer)
            %% which should be the ASCII representation of the
            %% last pool member number
            generate_seed_names(PoolStart+1, PoolStart + list_to_integer(PoolSizeStr), [])
    end.

generate_seed_names(Current, End, Acc) when Current == End -> lists:reverse(Acc);
generate_seed_names(Current, End, Acc) ->
    generate_seed_names(Current+1, End, [ [$s, $e, $e, $d, Current ] | Acc ]).

do_dns_lookups(CName, Acc) ->
    case attempt_dns_lookup(CName, ?DNS_RETRIES) of
        {error, _} = Error ->
            lager:error("DNS lookup of ~p resulted in ~p after ~p retries", [CName, Error, ?DNS_RETRIES]),
            Acc;
        {ok, DNSRecord} ->
            lager:debug("successful DNS lookup result: ~p for ~p", [lager:pr(DNSRecord, inet), CName]),
            convert_dns_records(DNSRecord) ++ Acc
    end.

maybe_make_seed_pool_names(Base, []) -> [Base];
maybe_make_seed_pool_names(Base, Additional) ->
    [_InitialCName, Domain] = string:split(Base, "."),
    [Base] ++ [ A ++ "." ++ Domain || A <- Additional ].

attempt_dns_lookup(_Name, 0) -> {error, too_many_lookup_attempts};
attempt_dns_lookup(Name, Attempts) ->
    case inet_res:gethostbyname(Name, inet, ?DNS_TIMEOUT) of
        {error, _} = Error ->
            lager:debug("name: ~p, attempt ~p: got ~p", [Name, Attempts, Error]),
            timer:sleep(?DNS_SLEEP),
            attempt_dns_lookup(Name, Attempts - 1);
        {ok, HostRec} -> {ok, HostRec}
    end.

convert_dns_records(#hostent{h_addr_list = AddrList}) ->
    [ format_dns_addr(A) || A <- AddrList ].

format_dns_addr(Addr) ->
    IPStr = inet:ntoa(Addr),
    PortList = application:get_env(libp2p, seed_dns_ports, ?DEFAULT_SEED_DNS_PORTS),
    PortStr = to_string(choose_random_element(PortList)),
    "/ip4/" ++ IPStr ++ "/tcp/" ++ PortStr.

to_string(V) when is_integer(V) -> integer_to_list(V);
to_string(V) when is_binary(V) -> binary_to_list(V);
to_string(V) when is_list(V) -> V.

drop_target(Worker=#worker{pid=WorkerPid, ref = Ref, kind = Kind},
            State=#state{workers=Workers}) ->
    libp2p_group_worker:clear_target(WorkerPid),
    lager:info("dropping target for ~p ~p", [Kind, WorkerPid]),
    KindMap = maps:get(Kind, Workers, #{}),
    NewWorkers = Workers#{Kind => KindMap#{Ref => Worker#worker{target = undefined}}},
    State#state{workers=NewWorkers}.

add_worker(Worker = #worker{kind = Kind, ref = Ref, pid=Pid, target = Target},
           State = #state{workers = Workers, targets = Targets, monitors=Monitors, tid=TID, workers_to_add=ToAdd}) ->
    MonitorRef = erlang:monitor(process, Pid),
    KindMap = maps:get(Kind, Workers, #{}),
    Workers1 = Workers#{Kind => KindMap#{Ref => Worker}},

    NewToAdd = [{Kind, Pid} | ToAdd],
    AddWorkerBatchSize = case application:get_env(libp2p, seed_node, false) of
                             true -> 100;
                             false -> 0
                         end,
    WorkersToAdd = case length(NewToAdd) > AddWorkerBatchSize  of
        true ->
            add_worker_pids(NewToAdd, TID),
            [];
        false ->
            NewToAdd
    end,

    State#state{workers = Workers1, targets = Targets#{Target => {Kind, Ref}}, monitors = Monitors#{MonitorRef => {Kind, Pid, Ref}}, workers_to_add=WorkersToAdd}.

add_worker_pids(NewWorkers, TID) ->
    lists:foreach(fun(Kind) ->
                          NewPids = [ P || {K, P} <- NewWorkers, is_process_alive(P), K == Kind],
                          lager:info("~p new pids of type ~p", [length(NewPids), Kind]),
                          case ets:lookup(TID, {Kind, gossip_workers}) of
                              [{{Kind, gossip_workers}, Pids}] ->
                                  ets:insert(TID, {{Kind, gossip_workers}, NewPids ++ Pids});
                              [] ->
                                  ets:insert(TID, {{Kind, gossip_workers}, NewPids})
                          end
                  end, [peerbook, seed, inbound]).


remove_worker(#worker{ref = Ref, kind = Kind, target = Target, pid=Pid},
              State = #state{workers = Workers, targets = Targets, tid=TID, workers_to_add=ToAdd}) ->
    KindMap = maps:get(Kind, Workers, #{}),
    Workers1 = Workers#{Kind => maps:remove(Ref, KindMap)},
    case lists:keymember(Pid, 2, ToAdd) of
        true ->
            State#state{workers = Workers1, targets = maps:remove(Target, Targets), workers_to_add=lists:keydelete(Pid, 2, ToAdd)};
        false ->
            case ets:lookup(TID, {deleted, gossip_workers}) of
                [{{deleted, gossip_workers}, DeletedPids}] ->
                    NewDeleted = [Pid|DeletedPids],
                    DeleteWorkerBatchSize = case application:get_env(libp2p, seed_node, false) of
                                                true -> 100;
                                                false -> 10
                                            end,
                    case length(NewDeleted) > DeleteWorkerBatchSize of
                        true ->
                            B = sets:from_list(NewDeleted),
                            lists:foreach(fun(FilterKind) ->
                                                  case ets:lookup(TID, {FilterKind, gossip_workers}) of
                                                      [{{FilterKind, gossip_workers}, Pids}] ->
                                                          %% we want to find the pids for this kind that have been deleted and remove them from the list and also the deleted list
                                                          A = sets:from_list(Pids),
                                                          NewPids = sets:to_list(sets:subtract(A, B)),
                                                          lager:info("Deleted ~p pids from ~p", [length(Pids) - length(NewPids), FilterKind]),
                                                          ets:insert(TID, {{FilterKind, gossip_workers}, NewPids});
                                                      [] ->
                                                          %% idk
                                                          ok
                                                  end
                                          end, [seed, peerbook, inbound]),
                            %% by definition we must have deleted everything
                            ets:insert(TID, {{deleted, gossip_workers}, []});
                        false ->
                            ets:insert(TID, {{deleted, gossip_workers}, NewDeleted})
                    end;
                [] ->
                    ets:insert(TID, {{deleted, gossip_workers}, [Pid]})
            end,

            State#state{workers = Workers1, targets = maps:remove(Target, Targets)}
    end.

lookup_worker(Ref, #state{workers=Workers}) ->
    maps:fold(
      fun(_, V, A) ->
              case maps:get(Ref, V, not_found) of
                  not_found ->
                      A;
                  Worker ->
                      Worker
              end
      end,
      not_found,
      Workers).

lookup_worker(Kind, Ref, #state{workers=Workers}) ->
    KindMap = maps:get(Kind, Workers, #{}),
    maps:get(Ref, KindMap, not_found).

lookup_worker_by_target(Target, #state{workers=Workers, targets = Targets}) ->
    case maps:get(Target, Targets, not_found) of
        not_found ->
            false;
        {Kind, Ref} ->
            KindMap = maps:get(Kind, Workers, #{}),
            maps:get(Ref, KindMap, false)
    end.

get_addrs(Workers) ->
    lists:append(do_get_addrs(maps:get(inbound, Workers, #{})),
                 do_get_addrs(maps:get(peerbook, Workers, #{}))).

do_get_addrs(Map) ->
    maps:fold(
      fun(_Ref, #worker{target = undefined}, Acc) ->
              Acc;
         (_Ref, #worker{target = Target}, Acc) ->
              TargetAddr = Target,
              [TargetAddr | Acc]
      end,
      [],
      Map).

get_workers(Workers) ->
    lists:append(do_get_workers(maps:get(inbound, Workers, #{})),
                 do_get_workers(maps:get(peerbook, Workers, #{}))).

do_get_workers(Map) ->
    maps:fold(
      fun(_Ref, #worker{target = undefined}, Acc) ->
              Acc;
         (_Ref, W, Acc) ->
              [W | Acc]
      end,
      [],
      Map).

-spec count_workers(libp2p_group_gossip:connection_kind(), #state{}) -> non_neg_integer().
count_workers(Kind, #state{workers=Workers}) ->
    KindMap = maps:get(Kind, Workers, #{}),
    maps:size(KindMap).

-spec start_inbound_worker(any(), string(), pid(), string(), #state{}) ->  {noreply, #state{}}.
start_inbound_worker(From, Target, StreamPid, Path, State = #state{tid=TID, sidejob_sup=WorkerSup, handlers=Handlers}) ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
    case sidejob_supervisor:start_child(
           WorkerSup,
           libp2p_group_worker, start_link,
           [Ref, inbound, StreamPid, libp2p_crypto:pubkey_bin_to_p2p(Target), self(), ?GROUP_ID, [], TID, Path]) of
        {ok, WorkerPid} ->
            maps:fold(fun(Key, {M, S}, Acc) ->
                                 case (catch M:init_gossip_data(S)) of
                                     {'EXIT', Reason} ->
                                         lager:warning("gossip handler ~s failed to init with error ~p", [M, Reason]),
                                         Acc;
                                     ok ->
                                         Acc;
                                     {send, Msg} ->
                                         libp2p_group_worker:send(WorkerPid, Key, Msg, true),
                                         Acc
                                 end
                      end, none, Handlers),
            case From of
                {raw, Pid, MsgRef} ->
                    Pid ! {MsgRef, ok};
                _ ->
                    gen_server:reply(From, ok)
            end,
            Parent ! {started_inbound_worker, {ok, #worker{kind=inbound, pid=WorkerPid, target=Target, ref=Ref}}};
        {error, overload}=Error ->
            case From of
                {raw, Pid, MsgRef} ->
                    Pid ! {MsgRef, Error};
                _ ->
                    gen_server:reply(From, Error)
            end
    end end),
    {noreply, State}.

-spec stop_inbound_worker(reference(), pid(), #state{}) -> #state{}.
stop_inbound_worker(StreamRef, Pid, State) ->
    spawn(fun() -> gen_statem:stop(Pid) end),
    case lookup_worker(inbound, StreamRef, State) of
        Worker = #worker{pid = Pid} ->
            remove_worker(Worker, State);
        Worker = #worker{pid = OtherPid} ->
            lager:info("pid mixup got ~p ref ~p", [Pid, OtherPid]),
            spawn(fun() -> gen_statem:stop(OtherPid) end),
            remove_worker(Worker, State);
        _ ->
            State
    end.

-spec start_worker(atom(), #state{}) -> {ok, #worker{}} | {error, overload}.
start_worker(Kind, #state{tid=TID, sidejob_sup = WorkerSup}) ->
    Ref = make_ref(),
    DialOptions = [],
    case sidejob_supervisor:start_child(
                        WorkerSup,
                        libp2p_group_worker, start_link,
                        [Ref, Kind, self(), ?GROUP_ID, DialOptions, TID]) of
        {ok, WorkerPid} ->
            {ok, #worker{kind=Kind, pid=WorkerPid, target=undefined, ref=Ref}};
        Other -> Other
    end.

-spec get_opt(libp2p_config:opts(), atom(), any()) -> any().
get_opt(Opts, Key, Default) ->
    libp2p_config:get_opt(Opts, [libp2p_group_gossip, Key], Default).

mk_multiaddr(Addr) when is_binary(Addr) ->
    libp2p_crypto:pubkey_bin_to_p2p(Addr);
mk_multiaddr(Value) ->
    Value.

update_metadata(State=#state{}) ->
    libp2p_lager_metadata:update(
      [
       {group_id, ?GROUP_ID}
      ]),
    State.

lookup_handler(TID, Key) ->
    case ets:lookup(TID, gossip_handlers) of
        [{gossip_handlers, Handlers}] ->
            case maps:find(Key, Handlers) of
                error -> error;
                {ok, {M, S}} ->
                    {ok, M, S}
            end;
        _ ->
            error
    end.
