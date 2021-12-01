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
-export([accept_stream/4, handle_identify/4, handle_data/4]).

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
         workers=#{} :: #{atom() => #{reference() => #worker{}}},
         targets=#{} :: #{string() => {atom(), reference()}},
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

handle_data(Pid, StreamPid, Key, {Path, Bin}) ->
    %% experimentally move decoding out to the caller
    ListOrData =
        case Key of
            "peer" ->
                {Path, libp2p_peer:decode_list(Bin)};
            _ ->
                {Path, Bin}
        end,
        %% check the cache, see the lookup_handler function for details
        case lookup_handler(Pid, Key) of
            error ->
                ok;
            {ok, M, S} ->
                %% Catch the callback response. This avoids a crash in the
                %% handler taking down the gossip worker itself.
                try M:handle_gossip_data(StreamPid, ListOrData, S) of
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

handle_call({connected_addrs, Kind}, _From, State=#state{}) ->
    {Addrs, _Pids} = lists:unzip(connections(Kind, State)),
    {reply, Addrs, State};
handle_call({connected_pids, Kind}, _From, State) ->
    {_Addrs, Pids} = lists:unzip(connections(Kind, State)),
    {reply, Pids, State};

handle_call({remove_handler, Key}, _From, State=#state{handlers=Handlers}) ->
    {reply, ok, State#state{handlers=maps:remove(Key, Handlers)}};

handle_call({handle_identify, StreamPid, Path, {ok, Identify}},
            _From, State) ->
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
                    case start_inbound_worker(Target, StreamPid, Path, State) of
                        {ok, Worker} -> {reply, ok, add_worker(Worker, State)};
                        {error, overload} -> {reply, {error, too_many}, State}
                    end
            end;
        %% There's an existing worker for the given address, re-assign
        %% the worker the new stream.
        #worker{pid=Worker} ->
            libp2p_group_worker:assign_stream(Worker, StreamPid, Path),
            {reply, ok, State}
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
    libp2p_session:identify(Session, self(), {ReplyRef, StreamPid, Path}),
    {noreply, State};

handle_cast({add_handler, Key, Handler}, State=#state{handlers=Handlers}) ->
    {noreply, State#state{handlers=maps:put(Key, Handler, Handlers)}};
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
handle_cast({request_target, seed, WorkerPid, Ref}, State=#state{tid=TID, seed_nodes=SeedAddrs}) ->
    {CurrentAddrs, _} = lists:unzip(connections(seed, State)),
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
handle_cast({send, all, Key, Fun}, State=#state{}) when is_function(Fun, 1) ->
    %% use a fun to generate the send data for each gossip peer
    %% this can be helpful to send a unique random subset of data to each peer
    %% find out what kind of connection we are dealing with and pass that type to the fun
    {_, SeedPids} = lists:unzip(connections(seed, State)),
    {_, PeerbookPids} = lists:unzip(connections(peerbook, State)),
    {_, InboundPids} = lists:unzip(connections(inbound, State)),
    spawn(fun() ->
                  [ libp2p_group_worker:send(Pid, Key, Fun(seed), true) || Pid <- SeedPids ],
                  [ libp2p_group_worker:send(Pid, Key, Fun(peerbook), true) || Pid <- PeerbookPids ],
                  [ libp2p_group_worker:send(Pid, Key, Fun(inbound), true) || Pid <- InboundPids ]
          end),
    {noreply, State};
handle_cast({send, Kind, Key, Fun}, State=#state{}) when is_function(Fun, 0) ->
    %% use a fun to generate the send data for each gossip peer
    %% this can be helpful to send a unique random subset of data to each peer
    {_, Pids} = lists:unzip(connections(Kind, State)),
    lists:foreach(fun(Pid) ->
                          Data = Fun(Kind),
                          %% Catch errors encoding the given arguments to avoid a bad key or
                          %% value taking down the gossip server
                          libp2p_group_worker:send(Pid, Key, Data, true)
                  end, Pids),
    {noreply, State};

handle_cast({send, Kind, Key, Data}, State=#state{bloom=Bloom}) ->
    case bloom:check(Bloom, {out, Data}) of
        true ->
            ok;
        false ->
            bloom:set(Bloom, {out, Data}),
            {_, Pids} = lists:unzip(connections(Kind, State)),
            lager:debug("sending data via connection pids: ~p",[Pids]),
            spawn(fun() ->
                          lists:foreach(fun(Pid) ->
                                                %% TODO we could check the connections's Address here for
                                                %% if we received this data from that address and avoid
                                                %% bouncing the gossip data back
                                                libp2p_group_worker:send(Pid, Key, Data, true)
                                        end, Pids)
                  end)
    end,
    {noreply, State};
handle_cast({send_ready, _Target, _Ref, false}, State=#state{}) ->
    %% Ignore any not ready messages from group workers. The gossip
    %% server only reacts to ready messages by sending initial
    %% gossip_data.
    {noreply, State};
handle_cast({send_ready, Target, _Ref, _Ready}, State=#state{}) ->
    case lookup_worker_by_target(Target, State) of
        #worker{pid=WorkerPid} ->
            NewState = maps:fold(fun(Key, {M, S}, Acc) ->
                                         case (catch M:init_gossip_data(S)) of
                                             {'EXIT', Reason} ->
                                                 lager:warning("gossip handler ~s failed to init with error ~p", [M, Reason]),
                                                 Acc#state{handlers=maps:remove(Key, Acc#state.handlers)};
                                             ok ->
                                                 Acc;
                                             {send, Msg} ->
                                                 libp2p_group_worker:send(WorkerPid, Key, Msg, true),
                                                 Acc
                                         end
                                 end, State, State#state.handlers),
            {noreply, NewState};
        _ ->
            {noreply, State}
    end;
handle_cast({send_result, _Ref, _Reason}, State=#state{}) ->
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

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
                                                        {libp2p_gossip_stream, server, [Path, ?MODULE, self(), Bloom]})
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
    lager:notice("Failed to identify stream ~p: ~p", [StreamPid, Error]),
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
                    case start_inbound_worker(Target, StreamPid, Path, State) of
                        {ok, Worker} ->
                            StreamPid ! {ReplyRef, ok},
                            {noreply, add_worker(Worker, State)};
                        {error, Reason} ->
                            StreamPid ! {error, Reason},
                            {noreply, State}
                    end
            end;
        %% There's an existing worker for the given address, re-assign
        %% the worker the new stream.
        #worker{pid=Worker} ->
            lager:debug("received identity for existing target ~p.  Stream: ~p",[Target, StreamPid]),
            libp2p_group_worker:assign_stream(Worker, StreamPid, Path),
            StreamPid ! {ReplyRef, ok},
            {noreply, State}
    end;
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
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


-spec connections(libp2p_group_gossip:connection_kind() | all, #state{})
                 -> [{MAddr::string(), Pid::pid()}].
connections(all, State = #state{workers=Workers}) ->
    lists:flatten(maps:fold(
      fun(Kind, _, Acc) ->
              Conns = connections(Kind, State),
              [Conns|Acc]
      end,
      [],
      Workers));
connections(Kind, #state{workers=Workers}) ->
    KindMap = maps:get(Kind, Workers, #{}),
    [ {Target, Pid} || #worker{target = Target, pid = Pid} <- maps:values(KindMap), Target /= undefined ].

assign_target(WorkerPid, WorkerRef, TargetAddrs, State=#state{workers=Workers, supported_paths = SupportedPaths, bloom=Bloom}) ->
    case length(TargetAddrs) of
        0 ->
            %% the ref is stable across restarts, so use that as the lookup key
            case lookup_worker(WorkerRef, State) of
                Worker=#worker{kind=seed, target=SelectedAddr, pid=StoredWorkerPid} when SelectedAddr /= undefined ->
                    %% don't give up on the seed nodes in case we're entirely offline
                    %% we need at least one connection to bootstrap the swarm
                    ClientSpec = {SupportedPaths, {libp2p_gossip_stream, [?MODULE, self(), Bloom]}},
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
            SelectedAddr = mk_multiaddr(choose_random_element(TargetAddrs)),
            ClientSpec = {SupportedPaths, {libp2p_gossip_stream, [?MODULE, self(), Bloom]}},
            libp2p_group_worker:assign_target(WorkerPid, {SelectedAddr, ClientSpec}),
            %% the ref is stable across restarts, so use that as the lookup key
            case lookup_worker(WorkerRef, State) of
                Worker=#worker{} ->
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
            lookup_seed_from_dns(TargetAddrs)
    end.

choose_random_element([E]) -> E;
choose_random_element(L) when is_list(L) ->
    lists:nth(rand:uniform(length(L)), L).

%% We will (try to) lookup seed IPs from a DNS cname, and fall back to
%% using the static seed list
lookup_seed_from_dns(TargetAddrs) ->
    case application:get_env(libp2p, seed_dns_cname, undefined) of
        undefined ->
            lager:error("Configured to use DNS to lookup seed node IP, but the cname is undefined", []),
            TargetAddrs;
        CName ->
            case attempt_dns_lookup(CName, ?DNS_RETRIES) of
                {error, _} = Error ->
                    lager:error("DNS lookup of ~p resulted in ~p; falling back", [CName, Error]),
                    TargetAddrs;
                {ok, DNSRecord} ->
                    lager:debug("successful DNS lookup result: ~p", [lager:pr(DNSRecord, inet)]),
                    %% to help migitate possible eclipse attacks we will blend the DNS results
                    %% with the static list of seed nodes
                    convert_dns_records(DNSRecord) ++ TargetAddrs
            end
    end.

attempt_dns_lookup(_Name, 0) -> {error, too_many_lookup_attempts};
attempt_dns_lookup(Name, Attempts) ->
    case inet_res:gethostbyname(Name, inet, ?DNS_TIMEOUT) of
        {error, _} = Error ->
            lager:debug("attempt ~p: got ~p", [Attempts, Error]),
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

add_worker(Worker = #worker{kind = Kind, ref = Ref, target = Target},
           State = #state{workers = Workers, targets = Targets}) ->
    KindMap = maps:get(Kind, Workers, #{}),
    Workers1 = Workers#{Kind => KindMap#{Ref => Worker}},
    State#state{workers = Workers1, targets = Targets#{Target => {Kind, Ref}}}.

remove_worker(#worker{ref = Ref, kind = Kind, target = Target},
              State = #state{workers = Workers, targets = Targets}) ->
    KindMap = maps:get(Kind, Workers, #{}),
    Workers1 = Workers#{Kind => maps:remove(Ref, KindMap)},
    State#state{workers = Workers1, targets = maps:remove(Target, Targets)}.

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

-spec start_inbound_worker(string(), pid(), string(), #state{}) ->  #worker{}.
start_inbound_worker(Target, StreamPid, Path, #state{tid=TID, sidejob_sup=WorkerSup, handlers=Handlers}) ->
    Ref = make_ref(),
    case sidejob_supervisor:start_child(
           WorkerSup,
           libp2p_group_worker, start_link,
           [Ref, inbound, StreamPid, self(), ?GROUP_ID, [], TID, Path]) of
        {ok, WorkerPid} ->
            spawn(fun() -> maps:fold(fun(Key, {M, S}, Acc) ->
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
                         end, none, Handlers)
                  end),
            {ok, #worker{kind=inbound, pid=WorkerPid, target=Target, ref=Ref}};
        {error, overload} ->
            {error, overload}
    end.

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
            lager:info("trying to stop worker with unknown ref ~p pid ~p", [StreamRef, Pid]),
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

lookup_handler(Pid, Key) ->
    %% XXX ASSUMPTION: gossip handlers are not removed or changed once added
    case get(Key) of
        undefined ->
            Res = gen_server:call(Pid, {handle_data, Key}, infinity),
            put(Key, {erlang:timestamp(), Res}),
            Res;
        {Time, Val} ->
            %% cache for 10 minutes
            case timer:now_diff(erlang:timestamp(), Time) > 600000000 of
                true ->
                    erase(Key),
                    lookup_handler(Pid, Key);
                false ->
                    Val
            end
    end.
