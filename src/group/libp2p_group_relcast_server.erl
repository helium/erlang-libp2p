-module(libp2p_group_relcast_server).

-include_lib("bitcask/include/bitcask.hrl").

-behavior(gen_server).
-behavior(libp2p_ack_stream).
-behavior(libp2p_info).

%% API
-export([start_link/4, handle_input/2, handle_ack/2, info/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% libp2p_ack_stream
-export([handle_data/3, accept_stream/4]).

-record(worker,
       { target :: string(),
         index :: pos_integer(),
         pid :: pid() | self,
         ready=false :: boolean()
       }).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         group_id :: string(),
         self_index :: pos_integer(),
         workers=[] :: [#worker{}],
         store :: reference(),
         out_keys=[] :: [msg_cache_entry()],
         in_keys=[] :: [msg_cache_entry()],
         handler :: atom(),
         handler_state :: any()
       }).

-define(INBOUND,  1).
-define(OUTBOUND, 0).
-define(GROUP_PATH_BASE, "relcast/").

-type msg_kind() :: ?OUTBOUND | ?INBOUND.
-type msg_key() :: binary().
-type msg_cache_entry() :: {pos_integer(), [msg_key()]}.

%% API
handle_input(Pid, Msg) ->
    gen_server:cast(Pid, {handle_input, Msg}).

handle_ack(Pid, Index) ->
    erlang:send(Pid, {handle_ack, Index}).

info(Pid) ->
    catch gen_server:call(Pid, info).

%% libp2p_ack_stream
handle_data(Pid, Ref, Bin) ->
    gen_server:call(Pid, {handle_data, Ref, Bin}, timer:seconds(30)).

accept_stream(Pid, MAddr, StreamPid, Path) ->
    gen_server:call(Pid, {accept_stream, MAddr, StreamPid, Path}).


%% gen_server
%%

start_link(TID, GroupID, Args, Sup) ->
    gen_server:start_link(?MODULE, [TID, GroupID, Args, Sup], []).

init([TID, GroupID, [Handler, HandlerArgs], Sup]) ->
    erlang:process_flag(trap_exit, true),
    case Handler:init(HandlerArgs) of
        {ok, Addrs, HandlerState} ->
            DataDir = libp2p_config:swarm_dir(TID, [groups, GroupID]),
            case bitcask:open(DataDir, [read_write, {max_file_size, 100*1024*1024},
                                        {dead_bytes_merge_trigger, 25*1024*1024},
                                        {dead_bytes_threshold, 12*1024*1024}]) of
                {error, Reason} -> {stop, {error, Reason}};
                Ref ->
                    self() ! {start_workers, lists:map(fun mk_multiaddr/1, Addrs)},
                    SelfAddr = libp2p_swarm:address(TID),
                    case lists:keyfind(SelfAddr, 2, lists:zip(lists:seq(1, length(Addrs)), Addrs)) of
                        {SelfIndex, SelfAddr} ->
                            {OutKeys, InKeys} = recover_msg_cache(Ref),
                            RecoveredHandlerState = case bitcask:get(Ref, <<"handler_state">>) of
                                                        {ok, Value} ->
                                                            Handler:deserialize_state(Value);
                                                        _ ->
                                                            HandlerState
                                                    end,
                            {ok, #state{sup=Sup, tid=TID, group_id=GroupID,
                                        self_index=SelfIndex,
                                        out_keys=OutKeys,
                                        in_keys=InKeys,
                                        handler=Handler, handler_state=RecoveredHandlerState, store=Ref}};
                        false ->
                            {stop, {error, {not_found, SelfAddr}}}
                    end
            end;
        {error, Reason} -> {stop, {error, Reason}}
    end.

recover_msg_cache(Ref) ->
    {A, B} = bitcask:fold_keys(Ref,
                               fun(#bitcask_entry{key = Key = <<Time:19/integer-signed-unit:8, Offset:19/integer-signed-unit:8, Kind:8/integer-unsigned, Index:16/integer-unsigned>>}, {OutKeys, InKeys}) ->
                                       case Kind of
                                           ?INBOUND ->
                                               {OutKeys, [{{Time, Offset}, {Index, Key}}|InKeys]};
                                           ?OUTBOUND ->
                                               {[{{Time, Offset}, {Index, Key}}|OutKeys], InKeys}
                                       end;
                                  (_, Acc)  ->
                                       Acc
                               end,
                               {[], []}),
    {sort_and_group_keys(A), sort_and_group_keys(B)}.

sort_and_group_keys(Input) ->
    lists:foldl(fun({_Order, {Index, Key}}, Acc) ->
                        case lists:keyfind(Index, 1, Acc) of
                            {Index, Keys} ->
                                lists:keyreplace(Index, 1, Acc,
                                                 {Index, lists:append(Keys, [Key])});
                            false ->
                                lists:keystore(Index, 1, Acc,
                                               {Index, [Key]})
                        end
                end, [], lists:keysort(1, Input)).

handle_call({accept_stream, _MAddr, _StreamPid, _Path}, _From, State=#state{workers=[]}) ->
    {reply, {error, not_ready}, State};
handle_call(dump_queues, _From, State = #state{store=Store, in_keys=IK, out_keys=OK}) ->
    Map = #{
      in => [ {Index - 1, lists:map(fun(Key) -> {ok, Value} = bitcask:get(Store, Key), Value end, Keys)} || {Index, Keys} <- IK ],
      out => [ {Index - 1, lists:map(fun(Key) -> {ok, Value} = bitcask:get(Store, Key), Value end, Keys)} || {Index, Keys} <- OK ]
     },
    {reply, Map, State};
handle_call({accept_stream, MAddr, StreamPid, Path}, _From, State=#state{}) ->
    case lookup_worker(mk_multiaddr(Path), #worker.target, State) of
        false ->
            {reply, {error, not_found}, State};
        #worker{pid=self} ->
            {reply, {error, bad_arg}, State};
        #worker{index=Index, pid=Worker} ->
            libp2p_group_worker:assign_stream(Worker, MAddr, StreamPid),
            {reply, {ok, Index}, State}
    end;
handle_call({handle_data, Index, Msg}, From, State0=#state{handler=Handler, handler_state=HandlerState,
                                                          self_index=_SelfIndex}) ->
    %% Incoming message, add to queue
    %% lager:debug("~p RECEIVED MESSAGE FROM ~p ~p", [SelfIndex, Index, Msg]),
    {[MsgKey], State} = store_message(?INBOUND, [Index], Msg, State0),

    %% Pass on to handler
    case Handler:handle_message(Index, Msg, HandlerState) of
        {NewHandlerState, Action} when Action == ok; Action == defer ->
            save_state(State, Handler, HandlerState, NewHandlerState),
            _Reply = gen_server:reply(From, Action),
            %% lager:debug("From: ~p, Action: ~p, Reply: ~p", [From, Action, _Reply]),
            {noreply, delete_message(MsgKey, State#state{handler_state=NewHandlerState})};
        {NewHandlerState, {send, Messages}=_Action} ->
            save_state(State, Handler, HandlerState, NewHandlerState),
            _Reply = gen_server:reply(From, ok),
            %% lager:debug("From: ~p, Action: ~p, Reply: ~p", [From, _Action, _Reply]),
            %% lager:debug("MessageSize: ~p", [length(Messages)]),
            %% Send messages
            {noreply, send_messages(Messages, delete_message(MsgKey, State#state{handler_state=NewHandlerState}))};
        {NewHandlerState, stop, Reason} ->
            {stop, Reason, NewHandlerState}
    end;
handle_call(workers, _From, State=#state{workers=Workers}) ->
    Response = lists:map(fun(#worker{target=Addr, pid=Worker}) ->
                                 {Addr, Worker}
                         end, Workers),
    {reply, Response, State};
handle_call(info, _From, State=#state{group_id=GroupID, handler=Handler, workers=Workers}) ->
    AddWorkerInfo = fun(#worker{pid=self}, Map) ->
                            maps:put(info, self, Map);
                       (#worker{pid=Pid, ready=true}, Map) ->
                            maps:put(info, libp2p_group_worker:info(Pid), Map);
                       (#worker{ready=false}, Map)->
                            Map
                    end,
    WorkerInfos = lists:foldl(fun(WorkerInfo=#worker{index=Index, ready=Ready}, Acc) ->
                                      maps:put(Index,
                                               AddWorkerInfo(WorkerInfo,
                                                             #{ index => Index,
                                                                ready => Ready}),
                                               Acc)
                              end, #{}, Workers),
    GroupInfo = #{
                  module => ?MODULE,
                  pid => self(),
                  group_id => GroupID,
                  handler => Handler,
                  worker_info => WorkerInfos
                 },
    {reply, GroupInfo, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Index, WorkerPid}, State=#state{}) ->
    #worker{target=Target} = lookup_worker(Index, State),
    libp2p_group_worker:assign_target(WorkerPid, Target),
    {noreply, State};
handle_cast({handle_input, Msg}, State=#state{handler=Handler, handler_state=HandlerState}) ->
    case Handler:handle_input(Msg, HandlerState) of
        {NewHandlerState, ok} ->
            save_state(State, Handler, HandlerState, NewHandlerState),
            {noreply, State#state{handler_state=NewHandlerState}};
        {NewHandlerState, {send, Messages}} ->
            save_state(State, Handler, HandlerState, NewHandlerState),
            %% Send messages
            NewState = send_messages(Messages, State),
            %% TODO: Store HandlerState
            {noreply, NewState#state{handler_state=NewHandlerState}};
        {NewHandlerState, stop, Reason} ->
            {stop, Reason, NewHandlerState}
        end;
handle_cast({send_ready, Index, Ready}, State0=#state{self_index=_SelfIndex}) ->
    %% Sent by group worker after it gets a stream set up (send just
    %% once per assigned stream). On normal cases use send_result as
    %% the place to send more messages.
    %% lager:debug("~p IS READY ~p TO SEND TO ~p", [SelfIndex, Ready, Index]),
    case is_ready_worker(Index, Ready, State0) of
        false ->
            State1 = ready_worker(Index, Ready, State0),
            case Ready of
                true ->
                    {noreply, dispatch_next_messages([Index], State1)};
                _ ->
                    {noreply, State1}
            end;
        _ ->
            {noreply, State0}
    end;
handle_cast({send_result, {Key, Index}, ok}, State=#state{self_index=_SelfIndex}) ->
    %% Sent by group worker. Since we use an ack_stream the message
    %% was acknowledged. Delete the outbound message for the given
    %% index
    %% lager:debug("~p SEND OK TO ~p: ~p ", [SelfIndex, Index, base58:binary_to_base58(Key)]),
    NewState = delete_message(Key, State),
    {noreply, dispatch_next_messages([Index], ready_worker(Index, true, NewState))};
handle_cast({send_result, {_Key, Index}, _Error}, State=#state{self_index=_SelfIndex}) ->
    %% Sent by group worker on error. Instead of looking up the
    %% message by key again we locate the first message that needs to
    %% be sent and dispatch it.
    %% lager:debug("~p SEND ERROR TO ~p: ~p ERR: ~p ", [_SelfIndex, Index, base58:binary_to_base58(_Key), _Error]),
    {noreply, dispatch_next_messages([Index], ready_worker(Index, true, State))};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, Targets}, State=#state{group_id=GroupID, tid=TID}) ->
    ServerPath = lists:flatten(?GROUP_PATH_BASE, GroupID),
    libp2p_swarm:add_stream_handler(libp2p_swarm:swarm(TID), ServerPath,
                                    {libp2p_ack_stream, server,[?MODULE, self()]}),
    {noreply, State#state{workers=start_workers(Targets, State)}};
handle_info({handle_ack, Index}, State=#state{}) ->
    %% lager:debug("RELCAST SERVER DISPATCHING ACK TO ~p", [Index]),
    {noreply, dispatch_ack(Index, State)};
handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{store=Store}) ->
    bitcask:close(Store).

%% Internal
%%

save_state(_State, _Handler, HandlerState, HandlerState) ->
    ok;
save_state(_State = #state{store=Store}, Handler, _OldHandlerState, NewHandlerState) ->
    {_KeyCount, Summary} = bitcask:status(Store),
    %FragPer = lists:sum([ Frag || {_, Frag, _, _} <- Summary ]) / max(1, length(Summary)),
    Empty =  [ Frag || {_, Frag, _, _} <- Summary, Frag == 100],

    %{_, IKs} = lists:unzip(State#state.in_keys),
    %{_, OKs} = lists:unzip(State#state.out_keys),


    %{O, I} = bitcask:fold_keys(Store, fun(#bitcask_entry{key = Key}, {OutKeys, InKeys}=Acc) ->
                                       %case Key of
                                           %<<_Time:19/integer-signed-unit:8, _Offset:19/integer-signed-unit:8, Kind:8/integer-unsigned, _Index:16/integer-unsigned>> when
                                                 %Kind == ?INBOUND ->
                                               %{OutKeys, InKeys+1};
                                           %<<_Time:19/integer-signed-unit:8, _Offset:19/integer-signed-unit:8, Kind:8/integer-unsigned, _Index:16/integer-unsigned>> when
                                                 %Kind == ?OUTBOUND ->
                                               %{OutKeys+1, InKeys};
                                           %_ ->
                                               %Acc
                                       %end
                               %end, {0, 0}),
    %lager:info("bitcask status ~p keys (~p outbound (~p in state), ~p inbound (~p in state)), ~p files (~p empty), ~p fragmented, ~p delete queue", [KeyCount, O, length(lists:flatten(OKs)), I, length(lists:flatten(IKs)), length(Summary), length(Empty), FragPer, bitcask_merge_delete:queue_length()]),
    case length(Empty) > 0 of
        true ->
            CaskDir = filename:dirname(element(1, hd(Summary))),
            _Res = bitcask:merge(CaskDir),
            bitcask_merge_delete:testonly__delete_trigger();
            %% lager:debug("forcing a bitcask merge on ~p ~p", [CaskDir, Res]);
        false ->
            ok
    end,
    case bitcask:put(Store, <<"handler_state">>, Handler:serialize_state(NewHandlerState)) of
        ok -> ok
    end.

-spec start_workers([string()], #state{}) -> [#worker{}].
start_workers(TargetAddrs, #state{sup=Sup, group_id=GroupID,  tid=TID,
                                  self_index=SelfIndex}) ->
    WorkerSup = libp2p_group_relcast_sup:workers(Sup),
    Path = lists:flatten([?GROUP_PATH_BASE, GroupID, "/",
                          libp2p_crypto:address_to_b58(libp2p_swarm:address(TID))]),
    lists:map(fun({Index, Addr}) when Index == SelfIndex ->
                      #worker{target=Addr, index=Index, pid=self, ready=true};
                  ({Index, Addr}) ->
                      ClientSpec = {Path, {libp2p_ack_stream, [Index, ?MODULE, self()]}},
                      {ok, WorkerPid} = supervisor:start_child(
                                          WorkerSup,
                                          #{ id => make_ref(),
                                             start => {libp2p_group_worker, start_link,
                                                       [Index, ClientSpec, self(), TID]},
                                             restart => permanent
                                           }),
                      %% sync on the mailbox having been flushed.
                      sys:get_status(WorkerPid),
                      #worker{target=Addr, index=Index, pid=WorkerPid, ready=false}
              end, lists:zip(lists:seq(1, length(TargetAddrs)), TargetAddrs)).

is_ready_worker(Index, Ready, State=#state{}) ->
    case lookup_worker(Index, State) of
        #worker{ready=Ready} -> Ready;
        _ -> false
    end.

ready_worker(Index, Ready, State=#state{}) ->
    case lookup_worker(Index, State) of
        Worker=#worker{} -> update_worker(Worker#worker{ready=Ready}, State);
        false -> State
    end.

-spec update_worker(#worker{}, #state{}) -> #state{}.
update_worker(Worker=#worker{index=Index}, State=#state{workers=Workers}) ->
    State#state{workers=lists:keystore(Index, #worker.index, Workers, Worker)}.

lookup_worker(Index, State=#state{}) ->
    lookup_worker(Index, #worker.index, State).

lookup_worker(Key, KeyIndex, #state{workers=Workers}) ->
    lists:keyfind(Key, KeyIndex, Workers).

-spec dispatch_ack(pos_integer(), #state{}) -> #state{}.
dispatch_ack(Index, State=#state{}) ->
    case lookup_worker(Index, State) of
        #worker{pid=self} -> State;
        #worker{pid=Worker} ->
            libp2p_group_worker:ack(Worker),
            State
    end.

-spec dispatch_next_messages([pos_integer()], #state{}) -> #state{}.
dispatch_next_messages(Indexes, State=#state{store=Store}) ->
    FilteredIndices = filter_ready_workers(Indexes, State),
    lists:foldl(fun({Index, [Key | _]}, Acc) ->
                        %% lager:debug("~p DISPATCHING NEXT TO ~p", [SelfIndex, Index]),
                        {ok, Msg} = bitcask:get(Store, Key),
                        case lookup_worker(Index, Acc) of
                            #worker{pid=self, ready=true} ->
                                %% Dispatch a message to self directly
                                Parent = self(),
                                %% lager:debug("~p DISPATCHING TO SELF: ~p",
                                %%             [SelfIndex, Index, base58:binary_to_base58(Key)]),
                                spawn(fun() ->
                                              Result = handle_data(Parent, Index, Msg),
                                              libp2p_group_server:send_result(Parent, {Key, Index}, Result)
                                      end),
                                ready_worker(Index, false, Acc);
                            #worker{index=Index, pid=Worker, ready=true} ->
                                %% lager:debug("~p DISPATCHING TO ~p: ~p",
                                %%             [SelfIndex, Index, base58:binary_to_base58(Key)]),
                                libp2p_group_worker:send(Worker, {Key, Index}, Msg),
                                ready_worker(Index, false, Acc)
                        end;
                   ({_Index, []}, Acc) -> Acc
                end, State, lookup_messages(?OUTBOUND, FilteredIndices, State)).

-spec filter_ready_workers([pos_integer()], #state{}) -> [pos_integer()].
filter_ready_workers(Indexes, State=#state{}) ->
    lists:filter(fun(Index) ->
                         case lookup_worker(Index, State) of
                             #worker{ready=true} -> true;
                             _ -> false
                         end
                    end, Indexes).

mk_multiaddr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_multiaddr(Path) when is_list(Path) ->
    lists:flatten(["/p2p", Path]).

-spec mk_message_key(msg_kind(), pos_integer()) -> binary().
mk_message_key(Kind, Index) ->
    {Time, Offset} = {erlang:monotonic_time(nanosecond), erlang:unique_integer([monotonic])},
    <<Time:19/integer-signed-unit:8, Offset:19/integer-signed-unit:8, Kind:8/integer-unsigned, Index:16/integer-unsigned>>.

-spec store_message(msg_kind(), Targets::[pos_integer()], Msg::binary(), #state{}) -> {[msg_key()], #state{}}.
store_message(Kind, Indexes, Msg, State=#state{store=Store}) ->
    NewKeys = lists:map(fun(I) -> mk_message_key(Kind, I) end, Indexes),
    StateEntry = case Kind of
                   ?INBOUND -> #state.in_keys;
                   ?OUTBOUND -> #state.out_keys
               end,
    NewStateKeys = lists:foldl(fun({Index, NewKey}, Acc) ->
                                       bitcask:put(Store, NewKey, Msg),
                                       case lists:keyfind(Index, 1, Acc) of
                                           {Index, Keys} ->
                                               lists:keyreplace(Index, 1, Acc,
                                                               {Index, lists:append(Keys, [NewKey])});
                                           false ->
                                               lists:keystore(Index, 1, Acc,
                                                             {Index, [NewKey]})
                                       end
                               end,
                               element(StateEntry, State),
                               lists:zip(Indexes, NewKeys)),
    {NewKeys, setelement(StateEntry, State, NewStateKeys)}.




-spec delete_message(msg_key(), #state{}) -> #state{}.
delete_message(Key, State=#state{store=Store}) ->
    bitcask:delete(Store, Key),
    <<_Time:19/integer-signed-unit:8, _Offset:19/integer-signed-unit:8,
      Kind:8/integer-unsigned, Index:16/integer-unsigned>> = Key,
    StateEntry = case Kind of
                   ?INBOUND -> #state.in_keys;
                   ?OUTBOUND -> #state.out_keys
               end,
    StateKeys = element(StateEntry, State),
    NewStateKeys = case lists:keyfind(Index, 1, StateKeys) of
                       false -> StateKeys;
                       {Index, Keys} ->
                           lists:keyreplace(Index, 1, StateKeys,
                                           {Index, lists:delete(Key, Keys)})
                   end,
    setelement(StateEntry, State, NewStateKeys).

-spec lookup_messages(msg_kind(), [pos_integer()], #state{}) -> [{pos_integer(), [msg_key()]}].
lookup_messages(Kind, Indices, State=#state{}) ->
    IndexSet = sets:from_list(Indices),
    %% lager:debug("BitcaskStatus: ~p", [bitcask:status(Store)]),
    %% StartTime = os:timestamp(),
    StateEntry = case Kind of
                   %?INBOUND -> #state.in_keys;
                   ?OUTBOUND -> #state.out_keys
               end,
    Res = lists:filter(fun({_Index, []}) -> false;
                          ({Index, _}) -> sets:is_element(Index, IndexSet)
                       end,
                       element(StateEntry, State)),
    %% lager:debug("BitcaskFoldTime: ~p", [timer:now_diff(os:timestamp(), StartTime)]),
    Res.

send_messages([], State=#state{}) ->
    State;
send_messages([{unicast, Index, Msg} | Tail], State=#state{}) ->
    {_, NewState} = store_message(?OUTBOUND, [Index], Msg, State),
    send_messages(Tail, dispatch_next_messages([Index], NewState));
send_messages([{multicast, Msg} | Tail], State=#state{workers=Workers, self_index=_SelfIndex}) ->
    Indexes = lists:seq(1, length(Workers)),
    %% lager:debug("~p STORED MULTICAST: ~p", [SelfIndex, base58:binary_to_base58(Key)]),
    {_, NewState} = store_message(?OUTBOUND, Indexes, Msg, State),
    send_messages(Tail, dispatch_next_messages(Indexes, NewState)).

%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

store_delete_test() ->
    Store = bitcask:open(test_util:nonl(os:cmd("mktemp -d")), [read_write]),
    State0 = #state{workers=lists:seq(1, 5), store=Store},
    {[InKey], State1} = store_message(?INBOUND, [0], <<"hello">>, State0),
    State2 = delete_message(InKey, State1),

    {[OutKey1, OutKey3], State3} = store_message(?OUTBOUND, [1, 3], <<"outbound">>, State2),
    {[OutKey12, OutKey32], State4} = store_message(?OUTBOUND, [1, 3], <<"outbound2">>, State3),
    ?assertEqual([{1, [OutKey1, OutKey12]}], lookup_messages(?OUTBOUND, [1], State4)),
    ?assertEqual([{3, [OutKey3, OutKey32]}], lookup_messages(?OUTBOUND, [3], State4)),

    State5 = delete_message(OutKey1, State4),
    not_found = bitcask:get(Store, OutKey1),
    {ok, _} = bitcask:get(Store, OutKey3),
    ?assertEqual([{1, [OutKey12]}], lookup_messages(?OUTBOUND, [1], State5)),

    State6 = delete_message(OutKey3, State5),
    not_found = bitcask:get(Store, OutKey3),
    ?assertEqual([{3, [OutKey32]}], lookup_messages(?OUTBOUND, [3], State6)),
    ok.

store_recover_test() ->
    Store = bitcask:open(test_util:nonl(os:cmd("mktemp -d")), [read_write]),
    State0 = #state{workers=lists:seq(1, 5), store=Store},
    {[InKey], State1} = store_message(?INBOUND, [0], <<"hello">>, State0),
    {OutKeys0, InKeys0} = recover_msg_cache(Store),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State1#state.in_keys), Y /= []], lists:keysort(1, InKeys0)),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State1#state.out_keys), Y /= []], lists:keysort(1, OutKeys0)),
    State2 = delete_message(InKey, State1),

    {[OutKey1, OutKey3], State3} = store_message(?OUTBOUND, [1, 3], <<"outbound">>, State2),
    {[_OutKey12, OutKey32], State4} = store_message(?OUTBOUND, [1, 3], <<"outbound2">>, State3),

    {OutKeys, InKeys} = recover_msg_cache(Store),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State4#state.in_keys), Y /= []], lists:keysort(1, InKeys)),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State4#state.out_keys), Y /= []], lists:keysort(1, OutKeys)),

    State5 = delete_message(OutKey1, State4),
    not_found = bitcask:get(Store, OutKey1),
    {ok, _} = bitcask:get(Store, OutKey3),

    {OutKeys2, InKeys2} = recover_msg_cache(Store),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State5#state.in_keys), Y /= []], lists:keysort(1, InKeys2)),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State5#state.out_keys), Y /= []], lists:keysort(1, OutKeys2)),


    State6 = delete_message(OutKey3, State5),
    not_found = bitcask:get(Store, OutKey3),
    ?assertEqual([{3, [OutKey32]}], lookup_messages(?OUTBOUND, [3], State6)),

    {OutKeys3, InKeys3} = recover_msg_cache(Store),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State6#state.in_keys), Y /= []], lists:keysort(1, InKeys3)),
    ?assertEqual([ {X, Y} || {X, Y} <- lists:keysort(1, State6#state.out_keys), Y /= []], lists:keysort(1, OutKeys3)),
    ok.

-endif.
