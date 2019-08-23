-module(libp2p_group_relcast_server).

-behavior(gen_server).
-behavior(libp2p_ack_stream).
-behavior(libp2p_info).

%% API
-export([
         start_link/4,
         status/1,
         handle_input/2,
         send_ack/4,
         info/1,
         handle_command/2]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% libp2p_ack_stream
-export([handle_data/3, handle_ack/4, accept_stream/3]).

-record(worker,
       { target :: string(),
         index :: pos_integer(),
         pid :: pid() | self,
         ready = false :: boolean(),
         in_flight = 0 :: non_neg_integer(),
         connects = 0 :: non_neg_integer(),
         last_take = unknown :: atom(),
         last_ack = 0 :: non_neg_integer()
       }).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         group_id :: string(),
         self_index :: pos_integer(),
         workers=[] :: [#worker{}],
         store = not_started :: not_started | cannot_start | relcast:relcast_state(),
         store_dir :: file:filename(),
         pending = #{} :: #{pos_integer() => {pos_integer(), binary()}},
         close_state=undefined :: undefined | closing
       }).

-define(INBOUND,  1).
-define(OUTBOUND, 0).
-define(GROUP_PATH_BASE, "relcast/").

%% API
status(Pid) ->
    try
        gen_server:call(Pid, status, 10000)
    catch _:_ ->
            {error, group_down}
    end.

handle_input(Pid, Msg) ->
    gen_server:cast(Pid, {handle_input, Msg}).

send_ack(Pid, Index, Seq, Reset) ->
    Pid ! {send_ack, Index, Seq, Reset}.

info(Pid) ->
    catch gen_server:call(Pid, info).

handle_command(Pid, Msg) ->
    gen_server:call(Pid, {handle_command, Msg}, 30000).

%% libp2p_ack_stream
%%

handle_data(Pid, Ref, Msgs) ->
    gen_server:cast(Pid, {handle_data, Ref, Msgs}).

handle_ack(Pid, Ref, Seq, Reset) ->
    gen_server:cast(Pid, {handle_ack, Ref, Seq, Reset}).

accept_stream(Pid, StreamPid, Path) ->
    gen_server:call(Pid, {accept_stream, StreamPid, Path}).


%% gen_server
%%

start_link(TID, GroupID, Args, Sup) ->
    gen_server:start_link(?MODULE, [TID, GroupID, Args, Sup], []).

init([TID, GroupID, Args, Sup]) ->
    RelcastArgs =
        case Args of
            [Handler, [Addrs|_] = HandlerArgs] ->
                [];
            [Handler, [Addrs|_] = HandlerArgs, RArgs] ->
                RArgs
        end,
    erlang:process_flag(trap_exit, true),
    DataDir = libp2p_config:swarm_dir(TID, [groups, GroupID]),
    SelfAddr = libp2p_swarm:pubkey_bin(TID),
    case lists:keyfind(SelfAddr, 2, lists:zip(lists:seq(1, length(Addrs)), Addrs)) of
        {SelfIndex, SelfAddr} ->
            %% we have to start relcast async because it might
            %% make a call to the process starting this process
            %% in its handler
            self() ! {start_relcast, Handler, HandlerArgs, RelcastArgs, SelfIndex, Addrs},
            {ok, update_metadata(#state{sup=Sup, tid=TID, group_id=GroupID,
                                        self_index=SelfIndex,
                                        store_dir=DataDir})};
        false ->
            {stop, {error, {not_found, SelfAddr}}}
    end.

handle_call(status, _From, State = #state{store=Store}) ->
    Reply =
        case Store of
            not_started ->
                not_started;
            cannot_start ->
                cannot_start;
            _ ->
                started
        end,
    {reply, Reply, State};
handle_call(dump_queues, _From, State = #state{store=Store}) ->
    {reply, relcast:status(Store), State};
handle_call({peek, ActorID}, _From, State = #state{store=Store}) ->
    %% take is no longer referentially transparent
    Res =
        case relcast:peek(ActorID, Store) of
            not_found ->
                not_found;
            {ok, Msg} ->
                Msg
        end,
    {reply, Res, State};
handle_call({accept_stream, _StreamPid, _Path}, _From, State=#state{workers=[]}) ->
    {reply, {error, not_ready}, State};
handle_call({accept_stream, StreamPid, Path}, _From, State=#state{}) ->
    case lookup_worker(mk_multiaddr(Path), #worker.target, State) of
        false ->
            {reply, {error, not_found}, State};
        #worker{pid=self} ->
            {reply, {error, bad_arg}, State};
        #worker{index=Index, pid=Worker} ->
            libp2p_group_worker:assign_stream(Worker, StreamPid),
            {reply, {ok, Index}, State}
    end;
handle_call(workers, _From, State=#state{workers=Workers}) ->
    Response = lists:map(fun(#worker{target=Addr, pid=Worker}) ->
                                 {Addr, Worker}
                         end, Workers),
    {reply, Response, State};
handle_call(info, _From, State=#state{group_id=GroupID, workers=Workers}) ->
    AddWorkerInfo = fun(#worker{pid=self}, Map) ->
                            maps:put(info, self, Map);
                       (#worker{pid=Pid}, Map) ->
                            maps:put(info, libp2p_group_worker:info(Pid), Map)
                    end,
    %QueueLen = fun(false) ->
                       %0;
                  %({_, Elements}) ->
                       %length(Elements)
               %end,
    WorkerInfos = lists:foldl(fun(WorkerInfo=#worker{target=Target, index=Index, in_flight=InFlight, last_ack=LastAck, ready=Ready, connects=Connections, last_take=LastTake}, Acc) ->
                                      %InKeys = QueueLen(lists:keyfind(Index, 1, State#state.in_keys)),
                                      %OutKeys = QueueLen(lists:keyfind(Index, 1, State#state.out_keys)),
                                      maps:put(Index,
                                               AddWorkerInfo(WorkerInfo,
                                                             #{ index => Index,
                                                                address => Target,
                                                                in_flight => InFlight,
                                                                last_ack => LastAck,
                                                                connects => Connections,
                                                                last_take => LastTake,
                                                                ready => Ready}),
                                               Acc)
                              end, #{}, Workers),
    GroupInfo = #{
                  module => ?MODULE,
                  pid => self(),
                  group_id => GroupID,
                  %handler => Handler,
                  worker_info => WorkerInfos
                 },
    {reply, GroupInfo, State};
handle_call({handle_command, _Msg}, _From, State=#state{close_state=closing}) ->
    {reply, {error, closing}, State};
handle_call({handle_command, Msg}, _From, State=#state{store=Relcast}) ->
    case relcast:command(Msg, Relcast) of
        {Reply, NewRelcast} ->
            {reply, Reply, dispatch_next_messages(State#state{store=NewRelcast})};
        {stop, Reply, Timeout, NewRelcast} ->
            erlang:send_after(Timeout, self(), force_close),
            {reply, Reply, dispatch_next_messages(State#state{store=NewRelcast})}
        end;
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Index, WorkerPid}, State=#state{tid=TID}) ->
    {Target, NewState} = case lookup_worker(Index, State) of
                             Worker = #worker{target=T, pid=OldPid} when WorkerPid /= OldPid ->
                                 lager:info("Worker for index ~p changed from ~p to ~p", [Index, OldPid, WorkerPid]),
                                 {T, update_worker(Worker#worker{pid=WorkerPid}, State)};
                             #worker{target=T} ->
                                 {T, State}
               end,
    Path = lists:flatten([?GROUP_PATH_BASE, State#state.group_id, "/",
                          libp2p_crypto:bin_to_b58(libp2p_swarm:pubkey_bin(TID))]),
    ClientSpec = {Path, {libp2p_ack_stream, [Index, ?MODULE, self(),
                                             {secured, libp2p_swarm:swarm(TID)}]}},
    libp2p_group_worker:assign_target(WorkerPid, {Target, ClientSpec}),
    {noreply, NewState};
handle_cast({handle_input, _Msg}, State=#state{close_state=closing}) ->
    {noreply, State};
handle_cast({handle_input, Msg}, State=#state{store=Relcast}) ->
    case relcast:command(Msg, Relcast) of
        {_Reply, NewRelcast} ->
            {noreply, dispatch_next_messages(State#state{store=NewRelcast})};
        {stop, _Reply, Timeout, NewRelcast} ->
            erlang:send_after(Timeout, self(), force_close),
            {noreply, dispatch_next_messages(State#state{store=NewRelcast})}
        end;
handle_cast({send_ready, _Target, Index, Ready}, State0=#state{self_index=_SelfIndex,
                                                               store=Relcast}) ->
    %% Sent by group worker after it gets a stream set up (send just
    %% once per assigned stream). On normal cases use send_result as
    %% the place to send more messages.
    %% lager:debug("~p IS READY ~p TO SEND TO ~p", [_SelfIndex, Ready, Index]),
    {ok, Relcast1} = relcast:reset_actor(Index, Relcast),
    State = State0#state{store = Relcast1, pending=maps:remove(Index, State0#state.pending)},
    case is_ready_worker(Index, Ready, State) of
        false ->
            {noreply, dispatch_next_messages(ready_worker(Index, Ready, State))};
        _ ->
            %% The worker ready state already matches
            {noreply, dispatch_next_messages(State)}
    end;
handle_cast({send_result, _Index, pending}, State=#state{self_index=_SelfIndex}) ->
    %% Send result from sending a message to a remote worker. Since the
    %% message is deferred we do not reset the worker on this side to
    %% ready. The remote end will dispatch a separate ack to resume
    %% message sends (handled in handle_ack).
    %% lager:debug("~p SEND RESULT TO ~p: ~p defer",
    %%             [_SelfIndex, _Index, base58:binary_to_base58(_Key)]),
    {noreply, State};
handle_cast({send_result, _Index, {error, _Error}}, State=#state{self_index=_SelfIndex}) ->
    %% For any other result error response we leave the worker busy
    %% and we wait for it to send us a new ready on a reconnect.
    {noreply, State};
handle_cast({handle_ack, Index, Seq, Reset}, State=#state{self_index=_SelfIndex}) ->
    %% Received when a previous message had a send_result of defer.
    %% We don't handle another defer here so it falls through to an
    %% unhandled cast below.
    %% Delete the outbound message for the given index
    {ok, RC} = relcast:ack(Index, Seq, State#state.store),
    NewRelcast = case Reset of
                     true ->
                         {ok, R} = relcast:reset_actor(Index, RC),
                         R;
                     false ->
                         RC
                 end,
    Worker = lookup_worker(Index, State),
    InFlight = relcast:in_flight(Index, NewRelcast),
    State1 = update_worker(Worker#worker{in_flight=InFlight, last_ack=erlang:system_time(second)}, State),
    {noreply, dispatch_next_messages(State1#state{store=NewRelcast})};
handle_cast({handle_data, Index, Msgs}, State=#state{self_index=_SelfIndex}) ->
    %% Incoming message, add to queue
    %% lager:debug("~p RECEIVED MESSAGE FROM ~p ~p", [SelfIndex, Index, Msg]),
    HasCanary = case State#state.pending of
                    #{Index := {_Seq2, _Msg2}} ->
                        true;
                    _ ->
                        false
                end,
    Res =
        lists:foldl(
          fun(M, {full, RC, Acc}) ->
                  {full, RC, [M | Acc]};
             ({Seq, Msg}, RC) ->
                  case relcast:deliver(Seq, Msg, Index, RC) of
                      full ->
                          {full, RC, [{Seq, Msg}]};

                  {ok, NewRC} ->
                      NewRC;
                  %% just keep looping, I guess, it kind of doesn't matter?
                  {stop, Timeout, NewRC} ->
                      erlang:send_after(Timeout, self(), force_close),
                      NewRC
                  end
          end,
          State#state.store,
          Msgs),
    case Res of
        {full, RC, PMsgs} ->
            %% So this is a bit tricky. we've exceeded the defer queueing for this
            %% peer ID so we need to queue it locally and block more being sent.
            %% We need to put these in a buffer somewhere and keep trying to deliver them
            %% every time we successfully process a message.

            %% Once we've hit this, we drop subsequent messages and send an actor reset
            %% when we do finally manage to deliver our pending canary.

            case HasCanary of
                %% already have something pending, drop.
                true ->
                    {noreply, dispatch_next_messages(State)};
                %% store it as a canary
                false ->
                    Pending = maps:put(Index, PMsgs, State#state.pending),
                    {noreply, dispatch_next_messages(State#state{store = RC,
                                                                 pending = Pending})}
            end;
        RC ->
            {noreply, dispatch_next_messages(State#state{store = RC})}
    end;
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

-dialyzer({nowarn_function, [start_relcast/6]}).
start_relcast(Handler, HandlerArgs, RelcastArgs, SelfIndex, Addrs, Store) ->
    relcast:start(SelfIndex, lists:seq(1, length(Addrs)), Handler,
                  HandlerArgs, [{data_dir, Store}|RelcastArgs]).

handle_info({start_workers, Targets}, State=#state{group_id=GroupID, tid=TID}) ->
    ServerPath = lists:flatten(?GROUP_PATH_BASE, GroupID),
    libp2p_swarm:add_stream_handler(libp2p_swarm:swarm(TID), ServerPath,
                                    {libp2p_ack_stream, server,[?MODULE, self(),
                                                                {secured, libp2p_swarm:swarm(TID)}]}),
    {noreply, State#state{workers=start_workers(Targets, State)}};
handle_info({start_relcast, Handler, HandlerArgs, RelcastArgs, SelfIndex, Addrs}, State) ->
    case start_relcast(Handler, HandlerArgs, RelcastArgs, SelfIndex, Addrs, State#state.store_dir) of
        {ok, Relcast} ->
            self() ! {start_workers, lists:map(fun mk_multiaddr/1, Addrs)},
            erlang:send_after(1500, self(), inbound_tick),
            {noreply, State#state{store=Relcast}};
        {error, {invalid_or_no_existing_store, _Msg}} ->
            lager:info("unable to start relcast: ~p", [_Msg]),
            {noreply, State#state{store=cannot_start}}
    end;
handle_info(force_close, State=#state{}) ->
    %% The timeout after the handler returned close has fired. Shut
    %% down the group by exiting the supervisor.
    spawn(fun() ->
                  libp2p_swarm:remove_group(State#state.tid, State#state.group_id)
          end),
    {noreply, State#state{close_state=closing}};
handle_info(inbound_tick, State = #state{store=Store}) ->
    case relcast:process_inbound(Store) of
        {ok, Acks, Store1} ->
            dispatch_acks(Acks, false, State),
            ok;
        {stop, Timeout, Store1} ->
            erlang:send_after(Timeout, self(), force_close),
            ok
    end,
    erlang:send_after(1500, self(), inbound_tick),
    {noreply, dispatch_next_messages(State#state{store=Store1})};
handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.


terminate(_, #state{close_state=closing, store=Store, store_dir=StoreDir}) ->
    relcast:stop(lite, Store),
    rm_rf(StoreDir);
terminate(_Reason, #state{store=Whatever}) when Whatever == cannot_start orelse
                                                Whatever == not_started ->
    ok;
terminate(Reason, #state{store=Store}) ->
    relcast:stop(Reason, Store).

%% Internal
%%

-spec rm_rf(file:filename()) -> ok.
rm_rf(Dir) ->
    Paths = filelib:wildcard(Dir ++ "/**"),
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
    ok = lists:foreach(fun file:delete/1, Files),
    Sorted = lists:reverse(lists:sort(Dirs)),
    ok = lists:foreach(fun file:del_dir/1, Sorted),
    file:del_dir(Dir).

-spec start_workers([string()], #state{}) -> [#worker{}].
start_workers(TargetAddrs, #state{sup=Sup, group_id=GroupID, tid=TID, self_index=SelfIndex}) ->
    WorkerSup = libp2p_group_relcast_sup:workers(Sup),
    lists:map(fun({Index, Addr}) when Index == SelfIndex ->
                      %% Dispatch a send_ready since there is no group
                      %% worker for self to do so
                      libp2p_group_server:send_ready(self(), Addr, SelfIndex, true),
                      #worker{target=Addr, index=Index, pid=self};
                  ({Index, Addr}) ->
                      {ok, WorkerPid} = supervisor:start_child(
                                          WorkerSup,
                                          #{ id => make_ref(),
                                             start => {libp2p_group_worker, start_link,
                                                       [Index, self(), GroupID, TID]},
                                             restart => transient
                                           }),
                      %% sync on the mailbox having been flushed.
                      sys:get_status(WorkerPid),
                      #worker{target=Addr, index=Index, pid=WorkerPid}
              end, lists:zip(lists:seq(1, length(TargetAddrs)), TargetAddrs)).

is_ready_worker(Index, Ready, State=#state{}) ->
    case lookup_worker(Index, State) of
        #worker{ready=R} -> R == Ready
    end.

-spec ready_worker(pos_integer(), boolean(), #state{}) -> #state{}.
ready_worker(Index, Ready, State=#state{}) ->
    case lookup_worker(Index, State) of
        Worker=#worker{} -> update_worker(Worker#worker{ready=Ready, connects=inc_connects(Worker#worker.connects, Ready)}, State);
        false -> State
    end.

inc_connects(N, true) ->
    N + 1;
inc_connects(N, false) ->
    N.

-spec update_worker(#worker{}, #state{}) -> #state{}.
update_worker(Worker=#worker{index=Index}, State=#state{workers=Workers}) ->
    State#state{workers=lists:keystore(Index, #worker.index, Workers, Worker)}.

-spec lookup_worker(pos_integer(), #state{}) -> #worker{} | false.
lookup_worker(Index, State=#state{}) ->
    lookup_worker(Index, #worker.index, State).

lookup_worker(Key, KeyIndex, #state{workers=Workers}) ->
    lists:keyfind(Key, KeyIndex, Workers).

-dialyzer({nowarn_function, [dispatch_acks/3]}).
-spec dispatch_acks(none | #{non_neg_integer() => [non_neg_integer()]},
                    boolean(), #state{}) -> ok.
dispatch_acks(none, _Reset, _State) ->
    ok;
dispatch_acks(Acks, Reset, State) ->
    maps:map(fun(Index, Seqs) ->
                     case lookup_worker(Index, State) of
                         #worker{pid=self} ->
                             handle_ack(self(), Index, Seqs, Reset),
                             State;
                         #worker{pid=Worker} ->
                             libp2p_group_worker:send_ack(Worker, Seqs, Reset),
                             State
                     end
             end,
             Acks),
    ok.

%% TODO: batch all acks per worker until the end of this call to ack
%% in larger batches

%% deliver to the workers in a round-robin fashion
%% until all the workers have run out of messages or filled
%% their pipelines
take_while([], State) ->
    State;
take_while([Worker | Workers], State) ->
    Index = Worker#worker.index,
    Count = application:get_env(libp2p, take_size, 25),
    case relcast:take(Index, State#state.store, Count) of
        {pipeline_full, NewRelcast} ->
            %% lager:info("take ~p pipeline full", [Index]),
            take_while(Workers, update_worker(Worker#worker{last_take=pipeline_full}, State#state{store = NewRelcast}));
        {not_found, NewRelcast} ->
            %% lager:info("take ~p not found", [Index]),
            take_while(Workers, update_worker(Worker#worker{last_take=not_found}, State#state{store = NewRelcast}));
        {ok, Msgs, Acks, NewRelcast} ->
            %% lager:info("take ~p got ~p", [Index, length(Msgs)]),
            libp2p_group_worker:send(Worker#worker.pid, Index, Msgs),
            dispatch_acks(Acks, false, State),
            InFlight = relcast:in_flight(Index, NewRelcast),
            NewWorker = Worker#worker{in_flight=InFlight, last_take=ok},
            State1 = update_worker(NewWorker, State#state{store=NewRelcast}),
            take_while(Workers ++ [NewWorker], State1)
    end.

-spec dispatch_next_messages(#state{}) -> #state{}.
dispatch_next_messages(State) ->
    NewState = case filter_ready_workers(State) of
                   [] ->
                       State;
                   Workers ->
                       take_while([W || W <- Workers], State)
               end,
    %% attempt to deliver some stuff in the pending queue
    maps:fold(
      fun(Index, Msgs, #state{store = RC} = A) ->
              Res =
                  lists:foldl(
                    fun(M, {full, Acc, R}) ->
                            {full, [M|Acc], R};
                       ({Seq, Msg} = M, {Acc, R}) ->
                            case relcast:deliver(Seq, Msg, Index, R) of
                                full ->
                                    %% still no room, continue to HODL the message
                                    {full, [M|Acc], R};
                                {ok, NR} ->
                                    {Acc, NR};
                                {stop, Timeout, NR} ->
                                    erlang:send_after(Timeout, self(), force_close),
                                    {Acc, NR}
                            end
                    end,
                    {[], RC}, Msgs),
              case Res of
                  {full, Rem, RC1} ->
                      A#state{store=RC1, pending=maps:put(Index, lists:reverse(Rem),
                                                          A#state.pending)};
                  {[], RC1} ->
                      A#state{store=RC1, pending=maps:remove(Index, A#state.pending)}
              end
      end, NewState, NewState#state.pending).


-spec filter_ready_workers(#state{}) -> [#worker{}].
filter_ready_workers(State=#state{}) ->
    lists:filter(fun(Worker) ->
                     case Worker of
                         #worker{pid=self} -> false;
                         #worker{ready=true} -> true;
                         _ -> false
                     end
                 end, State#state.workers).

mk_multiaddr(Addr) when is_binary(Addr) ->
    libp2p_crypto:pubkey_bin_to_p2p(Addr);
mk_multiaddr(Path) when is_list(Path) ->
    lists:flatten(["/p2p", Path]).

update_metadata(State=#state{group_id=GroupID}) ->
    libp2p_lager_metadata:update(
      [
       {group_id, GroupID}
      ]),
    State.
