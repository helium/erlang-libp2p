-module(libp2p_group_relcast_server).

-behavior(gen_server).
-behavior(libp2p_ack_stream).
-behavior(libp2p_info).

%% API
-export([start_link/4, handle_input/2, send_ack/5, info/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% libp2p_ack_stream
-export([handle_data/3, handle_ack/5, accept_stream/3]).

-record(worker,
       { target :: string(),
         index :: pos_integer(),
         pid :: pid() | self,
         ready = false :: boolean(),
         in_flight = 0 :: non_neg_integer(),
         connects = 0 :: non_neg_integer(),
         last_take = unknown :: atom(),
         last_in_seq :: undefined | pos_integer(),
         last_ack = 0 :: pos_integer()
       }).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         group_id :: string(),
         self_index :: pos_integer(),
         workers=[] :: [#worker{}],
         store :: undefined | relcast:relcast_state(),
         store_dir :: file:filename(),
         pending = #{} :: #{pos_integer() => {pos_integer(), binary()}},
         close_state=undefined :: undefined | closing
       }).

-define(INBOUND,  1).
-define(OUTBOUND, 0).
-define(GROUP_PATH_BASE, "relcast/").

%% API
handle_input(Pid, Msg) ->
    gen_server:cast(Pid, {handle_input, Msg}).

send_ack(Pid, Index, Seq, Reset, Range) ->
    Pid ! {send_ack, Index, Seq, Reset, Range}.

info(Pid) ->
    catch gen_server:call(Pid, info).

%% libp2p_ack_stream
%%

handle_data(Pid, Ref, {Bin, Seq, Last}) ->
    gen_server:cast(Pid, {handle_data, Ref, Bin, Seq, Last}).

handle_ack(Pid, Ref, Seq, Reset, Range) ->
    gen_server:cast(Pid, {handle_ack, Ref, Seq, Reset, Range}).

accept_stream(Pid, StreamPid, Path) ->
    gen_server:call(Pid, {accept_stream, StreamPid, Path}).


%% gen_server
%%

start_link(TID, GroupID, Args, Sup) ->
    gen_server:start_link(?MODULE, [TID, GroupID, Args, Sup], []).

init([TID, GroupID, [Handler, [Addrs|_] = HandlerArgs], Sup]) ->
    erlang:process_flag(trap_exit, true),
    DataDir = libp2p_config:swarm_dir(TID, [groups, GroupID]),
    SelfAddr = libp2p_swarm:pubkey_bin(TID),
    case lists:keyfind(SelfAddr, 2, lists:zip(lists:seq(1, length(Addrs)), Addrs)) of
        {SelfIndex, SelfAddr} ->
            %% we have to start relcast async because it might
            %% make a call to the process starting this process
            %% in its handler
            self() ! {start_relcast, Handler, HandlerArgs, SelfIndex, Addrs},
            {ok, update_metadata(#state{sup=Sup, tid=TID, group_id=GroupID,
                                        self_index=SelfIndex,
                                        store_dir=DataDir})};
        false ->
            {stop, {error, {not_found, SelfAddr}}}
    end.

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
    WorkerInfos = lists:foldl(fun(WorkerInfo=#worker{index=Index, in_flight=InFlight, last_ack=LastAck, ready=Ready, connects=Connections, last_take=LastTake}, Acc) ->
                                      %InKeys = QueueLen(lists:keyfind(Index, 1, State#state.in_keys)),
                                      %OutKeys = QueueLen(lists:keyfind(Index, 1, State#state.out_keys)),
                                      maps:put(Index,
                                               AddWorkerInfo(WorkerInfo,
                                                             #{ index => Index,
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
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Index, WorkerPid}, State=#state{}) ->
    {Target, NewState} = case lookup_worker(Index, State) of
                             Worker = #worker{target=T, pid=OldPid} when WorkerPid /= OldPid ->
                                 lager:info("Worker for index ~p changed from ~p to ~p", [Index, OldPid, WorkerPid]),
                                 {T, update_worker(Worker#worker{pid=WorkerPid}, State)};
                             #worker{target=T} ->
                                 {T, State}
               end,
    Path = lists:flatten([?GROUP_PATH_BASE, State#state.group_id, "/",
                          libp2p_crypto:bin_to_b58(libp2p_swarm:pubkey_bin(State#state.tid))]),
    ClientSpec = {Path, {libp2p_ack_stream, [Index, ?MODULE, self()]}},
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
handle_cast({handle_ack, Index, Seq, Reset, Range}, State=#state{self_index=_SelfIndex}) ->
    %% Received when a previous message had a send_result of defer.
    %% We don't handle another defer here so it falls through to an
    %% unhandled cast below.
    %% Delete the outbound message for the given index
    Relcast = case Range of
                  true ->
                      {ok, RC} = relcast:multi_ack(Index, Seq, State#state.store),
                      RC;
                  false ->
                      {ok, RC} = relcast:ack(Index, Seq, State#state.store),
                      RC
              end,
    NewRelcast = case Reset of
                     true ->
                         {ok, R} = relcast:reset_actor(Index, Relcast),
                         R;
                     false ->
                         Relcast
                 end,
    Worker = lookup_worker(Index, State),
    InFlight = relcast:in_flight(Index, NewRelcast),
    State1 = update_worker(Worker#worker{in_flight=InFlight, last_ack=erlang:system_time(second)}, State),
    {noreply, dispatch_next_messages(State1#state{store=NewRelcast})};
handle_cast({handle_data, Index, Msg, Seq, Last}, State=#state{self_index=_SelfIndex}) ->
    Worker = lookup_worker(Index, State),
    %% Incoming message, add to queue
    %% lager:debug("~p RECEIVED MESSAGE FROM ~p ~p", [SelfIndex, Index, Msg]),
    HasCanary = case State#state.pending of
                    #{Index := {_Seq2, _Msg2}} ->
                        true;
                    _ ->
                        false
                end,
    case relcast:deliver(Msg, Index, State#state.store) of
        full ->
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
                    Pending = maps:put(Index, {Seq, Msg}, State#state.pending),
                    %% ack the 'last' message as a range ack, if we have one
                    case Worker#worker.last_in_seq of
                        undefined ->
                            ok;
                        _ ->
                            dispatch_ack(Index, Worker#worker.last_in_seq, false, true, State)
                    end,
                    {noreply, dispatch_next_messages(update_worker(Worker#worker{last_in_seq=undefined}, State#state{pending = Pending}))}
            end;
        {ok, NewRelcast} ->
            NewWorker = case Last andalso not HasCanary of
                true ->
                    %% last message and we don't have a canary, do a range ACK
                    dispatch_ack(Index, Seq, false, true, State),
                    Worker;
                false when HasCanary ->
                    %% do a single ack because we are accepting a message with a pending canary
                    dispatch_ack(Index, Seq, false, false, State),
                    Worker;
                false ->
                    %% just don't ack this, wait for the last message or for our queue to fill up
                    Worker#worker{last_in_seq=Seq}
            end,
            {noreply, dispatch_next_messages(update_worker(NewWorker, State#state{store=NewRelcast}))};
        {stop, Timeout, NewRelcast} ->
            NewWorker = case Last andalso not HasCanary of
                true ->
                    %% last message and we don't have a canary, do a range ACK
                    dispatch_ack(Index, Seq, false, true, State),
                    Worker;
                false when HasCanary ->
                    %% do a single ack because we are accepting a message with a pending canary
                    dispatch_ack(Index, Seq, false, false, State),
                    Worker;
                false ->
                    %% just don't ack this, wait for the last message or for our queue to fill up
                    Worker#worker{last_in_seq=Seq}
            end,
            erlang:send_after(Timeout, self(), force_close),
            {noreply, dispatch_next_messages(update_worker(NewWorker, State#state{store=NewRelcast}))}
    end;
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, Targets}, State=#state{group_id=GroupID, tid=TID}) ->
    ServerPath = lists:flatten(?GROUP_PATH_BASE, GroupID),
    libp2p_swarm:add_stream_handler(libp2p_swarm:swarm(TID), ServerPath,
                                    {libp2p_ack_stream, server,[?MODULE, self()]}),
    {noreply, State#state{workers=start_workers(Targets, State)}};
handle_info({start_relcast, Handler, HandlerArgs, SelfIndex, Addrs}, State) ->
    {ok, Relcast} = relcast:start(SelfIndex, lists:seq(1, length(Addrs)), Handler, HandlerArgs, [{data_dir, State#state.store_dir}]),
    self() ! {start_workers, lists:map(fun mk_multiaddr/1, Addrs)},
    {noreply, State#state{store=Relcast}};
handle_info({send_ack, Index, Seq, Reset, Range}, State=#state{}) ->
    %% lager:debug("RELCAST SERVER DISPATCHING ACK TO ~p", [Index]),
    {noreply, dispatch_ack(Index, Seq, Reset, Range, State)};
handle_info(force_close, State=#state{}) ->
    %% The timeout after the handler returned close has fired. Shut
    %% down the group by exiting the supervisor.
    spawn(fun() ->
                  libp2p_swarm:remove_group(State#state.tid, State#state.group_id)
          end),
    {noreply, State};

handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.


terminate(normal, #state{close_state=closing, store=Store, store_dir=StoreDir}) ->
    relcast:stop(normal, Store),
    rm_rf(StoreDir);
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

-spec dispatch_ack(pos_integer(), pos_integer(), boolean(), boolean(), #state{}) -> #state{}.
dispatch_ack(Index, Seq, Reset, Range, State=#state{}) ->
    case lookup_worker(Index, State) of
        #worker{pid=self} ->
            handle_ack(self(), Index, Seq, Reset, Range),
            State;
        #worker{pid=Worker} ->
            libp2p_group_worker:send_ack(Worker, Seq, Reset, Range),
            State
    end.

%-spec close_workers(#state{}) -> #state{}.
%close_workers(State=#state{workers=Workers}) ->
    %lists:foreach(fun(#worker{pid=self}) ->
                          %ok;
                     %(#worker{pid=Pid}) ->
                          %libp2p_group_worker:close(Pid)
                  %end, Workers),
    %State.

%-spec close_check(#state{}) -> #state{}.
%close_check(State=#state{close_state=closing}) ->
    %% TODO
    %case count_messages(?OUTBOUND, all, State) of
        %0 -> self() ! force_close;
        %_ -> ok
    %end,
    %State;
%close_check(State) ->
    %State.

%% deliver to the workers in a round-robin fashion
%% until all the workers have run out of messages or filled
%% their pipelines
take_while([], State) ->
    State;
take_while([{Last, Sent, Worker}|Workers], State) ->
    Index = Worker#worker.index,
    case relcast:take(Index, State#state.store) of
        {pipeline_full, NewRelcast} ->
            maybe_send_last(Worker, Index, Last, true),
            take_while(Workers, update_worker(Worker#worker{last_take=pipeline_full}, State#state{store = NewRelcast}));
        {not_found, NewRelcast} ->
            maybe_send_last(Worker, Index, Last, true),
            take_while(Workers, update_worker(Worker#worker{last_take=not_found}, State#state{store = NewRelcast}));
        {ok, Seq, Msg, NewRelcast} ->
            %% send a 'last' packet every 5 packets so the pipeline doesn't run dry
            maybe_send_last(Worker, Index, Last, Sent == 5),
            InFlight = relcast:in_flight(Index, NewRelcast),
            NewWorker = Worker#worker{in_flight=InFlight, last_take=ok},
            State1 = update_worker(NewWorker, State#state{store=NewRelcast}),
            take_while(Workers ++ [{{Msg, Seq}, (Sent rem 5) + 1, NewWorker}], State1)
    end.

%% send the last taken message with a flag indicating if it's the last or more are
%% coming.
maybe_send_last(_Worker, _Index, undefined, _Last) ->
    ok;
maybe_send_last(Worker, Index, {Msg, Seq}, Last) ->
    libp2p_group_worker:send(Worker#worker.pid,  Index, {Msg, Seq, Last}).

-spec dispatch_next_messages(#state{}) -> #state{}.
dispatch_next_messages(State) ->
    NewState = case filter_ready_workers(State) of
                   [] ->
                       State;
                   Workers ->
                       take_while([{undefined, 0, W} || W <- Workers], State)
               end,
    %% attempt to deliver some stuff in the pending queue
    maps:fold(fun(Index, {Seq, Msg}, Acc) ->
                      case relcast:deliver(Msg, Index, Acc#state.store) of
                          full ->
                              %% still no room, continue to HODL the message
                              Acc;
                          {ok, NR} ->
                              dispatch_ack(Index, Seq, true, false, Acc),
                              Acc#state{store=NR, pending=maps:remove(Index, Acc#state.pending)};
                          {stop, Timeout, NR} ->
                              dispatch_ack(Index, Seq, true, false, Acc),
                              erlang:send_after(Timeout, self(), force_close),
                              Acc#state{store=NR, pending=maps:remove(Index, Acc#state.pending)}
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
