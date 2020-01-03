-module(libp2p_group_gossip_server).

-behaviour(gen_server).
-behavior(libp2p_gossip_stream).

%% API
-export([start_link/2]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% libp2p_gossip_stream
-export([accept_stream/3, handle_data/4]).

-record(worker,
       { target :: string() | undefined,
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
         workers=[] :: [#worker{}],
         handlers=#{} :: #{string() => libp2p_group_gossip:handler()},
         drop_timeout :: pos_integer(),
         drop_timer :: reference(),
         peer_cache_timeout :: pos_integer(),
         peer_cache_timer=make_ref() :: reference(),
         peer_cache=[] :: [string()]
       }).

-define(DEFAULT_PEERBOOK_CONNECTIONS, 5).
-define(DEFAULT_SEEDNODE_CONNECTIONS, 2).
-define(DEFAULT_MAX_INBOUND_CONNECTIONS, 10).
-define(DEFAULT_DROP_TIMEOUT, 5 * 60 * 1000).
%% Since fetching all known peers from the peerbook can take some
%% time, we cache the addresses for a number of seconds before
%% re-requesting, instead of fetching them every time, for every
%% worker that comes in to ask.
-define(DEFAULT_PEER_CACHE_TIMEOUT, 60 * 1000).
-define(GROUP_ID, "gossip").
-define(GROUP_PATH, "gossip/1.0.0").

%% API
%%

start_link(Sup, TID) ->
    gen_server:start_link(?MODULE, [Sup, TID], []).

%% libp2p_gossip_stream
%%

handle_data(Pid, StreamPid, Key, Bin) ->
    gen_server:cast(Pid, {handle_data, StreamPid, Key, Bin}).

accept_stream(Pid, SessionPid, StreamPid) ->
    gen_server:call(Pid, {accept_stream, SessionPid, StreamPid}).


%% gen_server
%%

init([Sup, TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_gossip_group(TID),
    Opts = libp2p_swarm:opts(TID),
    PeerBookCount = get_opt(Opts, peerbook_connections, ?DEFAULT_PEERBOOK_CONNECTIONS),
    SeedNodeCount = get_opt(Opts, seednode_connections, ?DEFAULT_SEEDNODE_CONNECTIONS),
    InboundCount = get_opt(Opts, inbound_connections, ?DEFAULT_MAX_INBOUND_CONNECTIONS),
    DropTimeOut = get_opt(Opts, drop_timeout, ?DEFAULT_DROP_TIMEOUT),
    PeerCacheTimeOut = get_opt(Opts, peer_cache_timeout, ?DEFAULT_PEER_CACHE_TIMEOUT),
    SeedNodes = get_opt(Opts, seed_nodes, []),
    self() ! peer_cache_timeout,
    self() ! start_workers,
    {ok, update_metadata(#state{sup=Sup, tid=TID,
                                seed_nodes=SeedNodes,
                                max_inbound_connections=InboundCount,
                                peerbook_connections=PeerBookCount,
                                seednode_connections=SeedNodeCount,
                                drop_timeout=DropTimeOut,
                                drop_timer=schedule_drop_timer(DropTimeOut),
                                peer_cache_timeout=PeerCacheTimeOut})}.

handle_call({accept_stream, _Session, _StreamPid}, _From, State=#state{workers=[]}) ->
    {reply, {error, not_ready}, State};
handle_call({accept_stream, Session, StreamPid}, From, State=#state{}) ->
    libp2p_session:identify(Session, self(), {From, StreamPid}),
    {noreply, State};
handle_call({connected_addrs, Kind}, _From, State=#state{}) ->
    {Addrs, _Pids} = lists:unzip(connections(Kind, State)),
    {reply, Addrs, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.


handle_cast({handle_data, StreamPid, Key, Msg}, State=#state{}) ->
    %% Incoming message from a gossip stream for a given key
    case maps:find(Key, State#state.handlers) of
        error -> {noreply, State};
        {ok, {M, S}} ->
            %% Catch the callback response. This avoids a crash in the
            %% handler taking down the gossip_server itself.
            catch M:handle_gossip_data(StreamPid, Msg, S),
            {noreply, State}
    end;

handle_cast({add_handler, Key, Handler}, State=#state{handlers=Handlers}) ->
    {noreply, State#state{handlers=maps:put(Key, Handler, Handlers)}};
handle_cast({remove_handler, Key}, State=#state{handlers=Handlers}) ->
    {noreply, State#state{handlers=maps:remove(Key, Handlers)}};

handle_cast({request_target, inbound, WorkerPid}, State=#state{}) ->
    {noreply, stop_inbound_worker(WorkerPid, State)};
handle_cast({request_target, peerbook, WorkerPid}, State0=#state{}) ->
    State = peer_cache(State0),
    PeerAddrs = State#state.peer_cache,
    {CurrentAddrs, _} = lists:unzip(connections(all, State)),
    LocalAddr = libp2p_swarm:p2p_address(State#state.tid),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [LocalAddr],
    %% Remove the current addrs from all possible peer addresses
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(PeerAddrs),
                                             sets:from_list(ExcludedAddrs))),
    {noreply, assign_target(WorkerPid, TargetAddrs, State)};
handle_cast({request_target, seed, WorkerPid}, State=#state{tid=TID, seed_nodes=SeedAddrs}) ->
    {CurrentAddrs, _} = lists:unzip(connections(all, State)),
    LocalAddr = libp2p_swarm:p2p_address(TID),
    %% Exclude the local swarm address from the available addresses
    ExcludedAddrs = CurrentAddrs ++ [LocalAddr],
    TargetAddrs = sets:to_list(sets:subtract(sets:from_list(SeedAddrs),
                                             sets:from_list(ExcludedAddrs))),
    {noreply, assign_target(WorkerPid, TargetAddrs, State)};
handle_cast({send, Key, Fun}, State=#state{}) when is_function(Fun, 0) ->
    %% use a fun to generate the send data for each gossip peer
    %% this can be helpful to send a unique random subset of data to each peer
    {_, Pids} = lists:unzip(connections(all, State)),
    lists:foreach(fun(Pid) ->
                          Data = Fun(),
                          %% Catch errors encoding the given arguments to avoid a bad key or
                          %% value taking down the gossip server
                          case (catch libp2p_gossip_stream:encode(Key, Data)) of
                              {'EXIT', Error} ->
                                  lager:warning("Error encoding gossip data ~p", [Error]);
                              Msg ->
                                  libp2p_group_worker:send(Pid, Key, Msg)
                          end
                  end, Pids),
    {noreply, State};

handle_cast({send, Key, Data}, State=#state{}) ->
    {_, Pids} = lists:unzip(connections(all, State)),
    %% Catch errors encoding the given arguments to avoid a bad key or
    %% value taking down the gossip server
    case (catch libp2p_gossip_stream:encode(Key, Data)) of
        {'EXIT', Error} ->
            lager:warning("Error encoding gossip data ~p", [Error]);
        Msg ->
            lists:foreach(fun(Pid) ->
                                  libp2p_group_worker:send(Pid, Key, Msg)
                          end, Pids)
    end,
    {noreply, State};
handle_cast({send_ready, _target, _Ref, false}, State=#state{}) ->
    %% Ignore any not ready messages from group workers. The gossip
    %% server only reacts to ready messages by sending initial
    %% gossip_data.
    {noreply, State};
handle_cast({send_ready, Target, _Ref, _Ready}, State=#state{}) ->
    case lookup_worker(Target, #worker.target, State) of
        #worker{pid=WorkerPid} ->
            NewState = maps:fold(fun(Key, {M, S}, Acc) ->
                                         case (catch M:init_gossip_data(S)) of
                                             {'EXIT', Reason} ->
                                                 lager:warning("gossip handler ~s failed to init with error ~p", [M, Reason]),
                                                 Acc#state{handlers=maps:remove(Key, Acc#state.handlers)};
                                             ok ->
                                                 Acc;
                                             {send, Data} ->
                                                 Msg = libp2p_gossip_stream:encode(Key, Data),
                                                 libp2p_group_worker:send(WorkerPid, send_ready, Msg),
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

handle_info(start_workers, State=#state{tid=TID, seednode_connections=SeedCount, peerbook_connections=PeerCount}) ->
    PeerBookWorkers = [start_worker(peerbook, State) || _ <- lists:seq(1, PeerCount)],
    SeedWorkers = [start_worker(seed, State) || _ <- lists:seq(1, SeedCount)],
    libp2p_swarm:add_stream_handler(TID, ?GROUP_PATH,
                                    {libp2p_gossip_stream, server, [?MODULE, self()]}),
    {noreply, State#state{workers=SeedWorkers ++ PeerBookWorkers}};
handle_info(drop_timeout, State=#state{drop_timeout=DropTimeOut, drop_timer=DropTimer,
                                       workers=Workers}) ->
    erlang:cancel_timer(DropTimer),
    case lists:filter(fun(#worker{target=MAddr}) -> MAddr =/= undefined end, Workers) of
        [] ->  {noreply, State#state{drop_timer=schedule_drop_timer(DropTimeOut)}};
        ConnectedWorkers ->
            Worker = lists:nth(rand:uniform(length(ConnectedWorkers)), ConnectedWorkers),
            lager:debug("Timeout dropping 1 connection: ~p]", [Worker#worker.target]),
            {noreply, drop_target(Worker, State#state{drop_timer=schedule_drop_timer(DropTimeOut)})}
    end;
handle_info(peer_cache_timeout, State=#state{}) ->
    erlang:send_after(State#state.peer_cache_timeout, self(), peer_cache_timeout),
    {noreply, peer_cache(State#state{peer_cache=[]})};
handle_info({handle_identify, {From, StreamPid}, {error, Error}}, State=#state{}) ->
    lager:notice("Failed to identify stream ~p: ~p", [StreamPid, Error]),
    gen_server:reply(From, {error, Error}),
    {noreply, State};
handle_info({handle_identify, {From, StreamPid}, {ok, Identify}}, State=#state{}) ->
    Target = libp2p_crypto:pubkey_bin_to_p2p(libp2p_identify:pubkey_bin(Identify)),
    %% Check if we already have a worker for this target
    case lookup_worker(Target, #worker.target, State) of
        %% If not, we we check if we can accept a random inbound
        %% connection and start a worker for the inbound stream if ok
        false ->
            case count_workers(inbound, State) > State#state.max_inbound_connections of
                true ->
                    lager:debug("Too many inbound workers: ~p",
                                [State#state.max_inbound_connections]),
                    gen_server:reply(From, {error, too_many}),
                    {noreply, State};
                false ->
                    NewWorkers = [start_inbound_worker(Target, StreamPid, State) | State#state.workers],
                    gen_server:reply(From, ok),
                    {noreply, State#state{workers=NewWorkers}}
            end;
        %% There's an existing worker for the given address, re-assign
        %% the worker the new stream.
        #worker{pid=Worker} ->
            libp2p_group_worker:assign_stream(Worker, StreamPid),
            gen_server:reply(From, ok),
            {noreply, State}
    end;
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{tid=TID}) ->
    libp2p_swarm:remove_stream_handler(TID, ?GROUP_PATH).



%% Internal
%%

-spec peer_cache(#state{}) -> #state{}.
peer_cache(State=#state{peer_cache=[], tid=TID}) ->
    case (catch libp2p_peerbook:keys(libp2p_swarm:peerbook(TID))) of
        {'EXIT', _} ->
            State;
        PeerKeys ->
            PeerAddrs = [ libp2p_crypto:pubkey_bin_to_p2p(Key) || Key <- PeerKeys ],
            State#state{peer_cache=PeerAddrs}
    end;
peer_cache(State=#state{}) ->
    State.

-spec schedule_drop_timer(pos_integer()) -> reference().
schedule_drop_timer(DropTimeOut) ->
    erlang:send_after(DropTimeOut, self(), drop_timeout).


-spec connections(libp2p_group_gossip:connection_kind() | all, #state{})
                 -> [{MAddr::string(), Pid::pid()}].
connections(Kind, #state{workers=Workers}) ->
    lists:foldl(fun(#worker{target=undefined}, Acc) ->
                        Acc;
                    (#worker{pid=Pid, target=MAddr}, Acc) when Kind == all ->
                        [{MAddr, Pid} | Acc];
                    (#worker{kind=WorkerKind, pid=Pid, target=MAddr}, Acc) when WorkerKind == Kind ->
                        [{MAddr, Pid} | Acc];
                   (_, Acc) ->
                        Acc
                end, [], Workers).

assign_target(WorkerPid, TargetAddrs, State=#state{workers=Workers}) ->
    case length(TargetAddrs) of
        0 ->
            case lookup_worker(WorkerPid, #worker.pid, State) of
                #worker{kind=seed, target=SelectedAddr} when SelectedAddr /= undefined ->
                    %% don't give up on the seed nodes in case we're entirely offline
                    %% we need at least one connection to bootstrap the swarm
                    ClientSpec = {?GROUP_PATH, {libp2p_gossip_stream, [?MODULE, self()]}},
                    libp2p_group_worker:assign_target(WorkerPid, {SelectedAddr, ClientSpec});
                _ ->
                    ok
            end,
            State;
        _ ->
            SelectedAddr = mk_multiaddr(lists:nth(rand:uniform(length(TargetAddrs)), TargetAddrs)),
            ClientSpec = {?GROUP_PATH, {libp2p_gossip_stream, [?MODULE, self()]}},
            libp2p_group_worker:assign_target(WorkerPid, {SelectedAddr, ClientSpec}),
            case lookup_worker(WorkerPid, #worker.pid, State) of
                Worker=#worker{} ->
                    NewWorkers = lists:keyreplace(WorkerPid, #worker.pid, Workers,
                                                  Worker#worker{target=SelectedAddr}),
                    State#state{workers=NewWorkers};
                _ ->
                    State
            end
    end.

drop_target(Worker=#worker{pid=WorkerPid}, State=#state{workers=Workers}) ->
    libp2p_group_worker:clear_target(WorkerPid),
    NewWorkers = lists:keyreplace(WorkerPid, #worker.pid, Workers,
                                  Worker#worker{target=undefined}),
    State#state{workers=NewWorkers}.

lookup_worker(Key, KeyIndex, #state{workers=Workers}) ->
    lists:keyfind(Key, KeyIndex, Workers).


-spec count_workers(libp2p_group_gossip:connection_kind(), #state{}) -> non_neg_integer().
count_workers(Kind, #state{workers=Workers}) ->
    FilteredWorkers = lists:filter(fun(#worker{kind=WorkerKind}) ->
                                          WorkerKind == Kind
                                  end, Workers),
    length(FilteredWorkers).

-spec start_inbound_worker(string(), pid(), #state{}) ->  #worker{}.
start_inbound_worker(Target, StreamPid, #state{tid=TID, sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    Ref = make_ref(),
    {ok, WorkerPid} = supervisor:start_child(
                        WorkerSup,
                        #{ id => Ref,
                           start => {libp2p_group_worker, start_link,
                                     [inbound, StreamPid, self(), ?GROUP_ID, TID]},
                           restart => temporary
                         }),
    #worker{kind=inbound, pid=WorkerPid, target=Target, ref=Ref}.

-spec stop_inbound_worker(pid(), #state{}) -> #state{}.
stop_inbound_worker(StreamPid, State) ->
    case lookup_worker(StreamPid, #worker.pid, State) of
        #worker{ref=Ref} ->
            WorkerSup = libp2p_group_gossip_sup:workers(State#state.sup),
            supervisor:terminate_child(WorkerSup, Ref),
            State#state{workers=lists:keydelete(StreamPid, #worker.pid, State#state.workers)};
        _ ->
            State
    end.

-spec start_worker(atom(), #state{}) -> #worker{}.
start_worker(Kind, #state{tid=TID, sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    Ref = make_ref(),
    {ok, WorkerPid} = supervisor:start_child(
                        WorkerSup,
                        #{ id => Ref,
                           start => {libp2p_group_worker, start_link,
                                     [Kind, self(), ?GROUP_ID, TID]},
                           restart => transient
                         }),
    #worker{kind=Kind, pid=WorkerPid, target=undefined, ref=Ref}.

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
