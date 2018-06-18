-module(libp2p_group_relcast_server).

-include_lib("bitcask/include/bitcask.hrl").

-behavior(gen_server).
-behavior(libp2p_ack_stream).

%% API
-export([start_link/4, handle_input/2, handle_ack/2]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% libp2p_ack_stream
-export([handle_data/3, accept_stream/4]).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         group_id :: string(),
         self_index :: pos_integer(),
         workers=[] :: [worker_info()],
         store :: reference(),
         handler :: atom(),
         handler_state :: any()
       }).

-define(INBOUND,  1).
-define(OUTBOUND, 0).
-define(GROUP_PATH_BASE, "relcast/").

-type worker_info() :: {MAddr::string(), Index::pos_integer(), pid() | self, Ready::boolean()}.
-type msg_kind() :: ?OUTBOUND | ?INBOUND.
-type msg_key() :: binary().

%% API
handle_input(Pid, Msg) ->
    gen_server:cast(Pid, {handle_input, Msg}).

handle_ack(Pid, Index) ->
    erlang:send(Pid, {handle_ack, Index}).


%% libp2p_ack_stream
handle_data(Pid, Ref, Bin) ->
    gen_server:call(Pid, {handle_data, Ref, Bin}, timer:seconds(30)).

accept_stream(Pid, MAddr, StreamPid, Path) ->
    gen_server:call(Pid, {accept_stream, MAddr, StreamPid, Path}).


%% gen_server
%%

start_link(TID, GroupID, Args, Sup) ->
    gen_server:start_link(?MODULE, [TID, GroupID, Args, Sup], []).

%% bitcask:open does not pass dialyzer correctly so we turn of the
%% using init/1 function (as we do in peerbook)
-dialyzer({nowarn_function, [init/1]}).

init([TID, GroupID, [Handler, HandlerArgs], Sup]) ->
    erlang:process_flag(trap_exit, true),
    case Handler:init(HandlerArgs) of
        {ok, Addrs, HandlerState} ->
            DataDir = libp2p_config:swarm_dir(TID, [groups, GroupID]),
            case bitcask:open(DataDir, [read_write]) of
                {error, Reason} -> {stop, {error, Reason}};
                Ref ->
                    self() ! {start_workers, lists:map(fun mk_multiaddr/1, Addrs)},
                    SelfAddr = libp2p_swarm:address(TID),
                    case lists:keyfind(SelfAddr, 2, lists:zip(lists:seq(1, length(Addrs)), Addrs)) of
                        {SelfIndex, SelfAddr} ->
                            {ok, #state{sup=Sup, tid=TID, group_id=GroupID,
                                        self_index=SelfIndex,
                                        handler=Handler, handler_state=HandlerState, store=Ref}};
                        false ->
                            {stop, {error, {not_found, SelfAddr}}}
                    end
            end;
        {error, Reason} -> {stop, {error, Reason}}
    end.

handle_call({accept_stream, _MAddr, _StreamPid, _Path}, _From, State=#state{workers=[]}) ->
    {reply, {error, not_ready}, State};
handle_call({accept_stream, MAddr, StreamPid, Path}, _From,
            State=#state{self_index=SelfIndex, workers=Workers}) ->
    case lists:keyfind(mk_multiaddr(Path), 1, Workers) of
        false ->
            {reply, {error, not_found}, State};
        {_, SelfIndex, self, _} ->
            {reply, {errror, bad_arg}, State};
        {_, Index, Worker, _} ->
            libp2p_group_worker:assign_stream(Worker, MAddr, StreamPid),
            {reply, {ok, Index}, State}
    end;
handle_call({handle_data, Index, Msg}, From, State=#state{handler=Handler, handler_state=HandlerState,
                                                          self_index=SelfIndex}) ->
    %% Incoming message, add to queue
    lager:debug("~p RECEIVED MESSAGE FROM ~p ~p", [SelfIndex, Index, Msg]),
    [MsgKey] = store_message(?INBOUND, [Index], Msg, State),

    %% Pass on to handler
    case Handler:handle_message(Index, Msg, HandlerState) of
        {NewHandlerState, Action} when Action == ok; Action == defer ->
            Reply = gen_server:reply(From, Action),
            lager:debug("From: ~p, Action: ~p, Reply: ~p", [From, Action, Reply]),
            delete_message(MsgKey, State),
            {noreply, State#state{handler_state=NewHandlerState}};
        {NewHandlerState, {send, Messages}=Action} ->
            Reply = gen_server:reply(From, ok),
            lager:debug("From: ~p, Action: ~p, Reply: ~p", [From, Action, Reply]),
            delete_message(MsgKey, State),
            lager:debug("MessageSize: ~p", [length(Messages)]),
            %% Send messages
            NewState = send_messages(Messages, State),
            %% TODO: Store HandlerState
            {noreply, NewState#state{handler_state=NewHandlerState}};
        {NewHandlerState, stop, Reason} ->
            {stop, Reason, NewHandlerState}
    end;
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Index, WorkerPid}, State=#state{workers=Workers}) ->
    {Target, Index, _WorkerPid, _} = lists:keyfind(Index, 2, Workers),
    libp2p_group_worker:assign_target(WorkerPid, Target),
    {noreply, State};
handle_cast({handle_input, Msg}, State=#state{handler=Handler, handler_state=HandlerState}) ->
    case Handler:handle_input(Msg, HandlerState) of
        {NewHandlerState, ok} ->
            {noreply, State#state{handler_state=NewHandlerState}};
        {NewHandlerState, {send, Messages}} ->
            %% Send messages
            NewState = send_messages(Messages, State),
            %% TODO: Store HandlerState
            {noreply, NewState#state{handler_state=NewHandlerState}};
        {NewHandlerState, stop, Reason} ->
            {stop, Reason, NewHandlerState}
        end;
handle_cast({send_ready, Index, Ready}, State0=#state{self_index=SelfIndex}) ->
    %% Sent by group worker after it gets a stream set up (send just
    %% once per assigned stream). On normal cases use send_result as
    %% the place to send more messages.
    lager:debug("~p IS READY ~p TO SEND TO ~p", [SelfIndex, Ready, Index]),
    State1 = ready_worker(Index, Ready, State0),
    case Ready of
        true ->
            {noreply, dispatch_next_messages([Index], State1)};
        _ ->
            {noreply, State1}
    end;
handle_cast({send_result, {Key, Index}, ok}, State=#state{self_index=SelfIndex}) ->
    %% Sent by group worker. Since we use an ack_stream the message
    %% was acknowledged. Delete the outbound message for the given
    %% index
    lager:debug("~p SEND OK TO ~p: ~p ", [SelfIndex, Index, base58:binary_to_base58(Key)]),
    delete_message(Key, State),
    {noreply, dispatch_next_messages([Index], ready_worker(Index, true, State))};
handle_cast({send_result, {Key, Index}, Error}, State=#state{self_index=SelfIndex}) ->
    %% Sent by group worker on error. Instead of looking up the
    %% message by key again we locate the first message that needs to
    %% be sent and dispatch it.
    lager:debug("~p SEND ERROR TO ~p: ~p ERR: ~p ", [SelfIndex, Index, base58:binary_to_base58(Key), Error]),
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
    lager:debug("RELCAST SERVER DISPATCHING ACK TO ~p", [Index]),
    {noreply, dispatch_ack(Index, State)};
handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{store=Store}) ->
    bitcask:close(Store).

%% Internal
%%

-spec start_workers([string()], #state{}) -> [worker_info()].
start_workers(TargetAddrs, #state{sup=Sup, group_id=GroupID,  tid=TID,
                                  self_index=SelfIndex}) ->
    WorkerSup = libp2p_group_relcast_sup:workers(Sup),
    Path = lists:flatten([?GROUP_PATH_BASE, GroupID, "/",
                          libp2p_crypto:address_to_b58(libp2p_swarm:address(TID))]),
    lists:map(fun({Index, Addr}) when Index == SelfIndex ->
                      {Addr, Index, self, true};
                  ({Index, Addr}) ->
                      ClientSpec = {Path, {libp2p_ack_stream, [Index, ?MODULE, self()]}},
                      {ok, WorkerPid} = supervisor:start_child(
                                          WorkerSup,
                                          #{ id => make_ref(),
                                             start => {libp2p_group_worker, start_link,
                                                       [Index, ClientSpec, self(), TID]},
                                             restart => permanent
                                           }),
                      sys:get_status(WorkerPid),
                      {Addr, Index, WorkerPid, false}
              end, lists:zip(lists:seq(1, length(TargetAddrs)), TargetAddrs)).

ready_worker(Index, Ready, State=#state{workers=Workers}) ->
    NewWorkers = case lists:keyfind(Index, 2, Workers) of
                     {Addr, Index, WorkerPid, _} ->
                         lists:keystore(Index, 2, Workers, {Addr, Index, WorkerPid, Ready});
                     false -> Workers
                 end,
    State#state{workers=NewWorkers}.

lookup_worker(Index, #state{workers=Workers}) ->
    lists:keyfind(Index, 2, Workers).

-spec dispatch_ack(pos_integer(), #state{}) -> #state{}.
dispatch_ack(Index, State=#state{self_index=SelfIndex}) ->
    case lookup_worker(Index, State) of
        {_, SelfIndex, self, _} -> State;
        {_, Index, Worker, _} ->
            libp2p_group_worker:ack(Worker),
            State
    end.

-spec dispatch_next_messages([pos_integer()], #state{}) -> #state{}.
dispatch_next_messages(Indices, State=#state{self_index=SelfIndex, store=Store}) ->
    FilteredIndices = filter_ready_workers(Indices, State, []),
    lists:foldl(fun({Index, [Key | _]}, Acc) ->
                        lager:debug("~p DISPATCHING NEXT TO ~p", [SelfIndex, Index]),
                        case lookup_worker(Index, Acc) of
                            {_, SelfIndex, self, true} ->
                                %% Dispatch a message to self directly
                                Parent = self(),
                                lager:debug("~p DISPATCHING TO SELF: ~p",
                                            [SelfIndex, Index, base58:binary_to_base58(Key)]),
                                {ok, Msg} = bitcask:get(Store, Key),
                                spawn(fun() ->
                                              Result = handle_data(Parent, Index, Msg),
                                              libp2p_group_server:send_result(Parent, {Key, Index}, Result)
                                      end),
                                ready_worker(Index, false, Acc);
                            {_, Index, Worker, true} ->
                                lager:debug("~p DISPATCHING TO ~p: ~p",
                                            [SelfIndex, Index, base58:binary_to_base58(Key)]),
                                {ok, Msg} = bitcask:get(Store, Key),
                                libp2p_group_worker:send(Worker, {Key, Index}, Msg),
                                ready_worker(Index, false, Acc)
                        end
                end, State, lookup_messages(?OUTBOUND, FilteredIndices, State)).

-spec filter_ready_workers([pos_integer()], #state{}, [pos_integer()]) -> [pos_integer()].
filter_ready_workers([], #state{}, Acc) ->
    Acc;
filter_ready_workers([Index | Tail], State=#state{}, Acc) ->
    case lookup_worker(Index, State) of
        {_, _, _, true} -> filter_ready_workers(Tail, State, [Index | Acc]);
        _ -> filter_ready_workers(Tail, State, Acc)
    end.

mk_multiaddr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_multiaddr(Path) when is_list(Path) ->
    lists:flatten(["/p2p", Path]).

-spec mk_message_key(msg_kind(), pos_integer()) -> binary().
mk_message_key(Kind, Index) ->
    {Time, Offset} = {erlang:monotonic_time(nanosecond), erlang:unique_integer([monotonic])},
    <<Time:19/integer-signed-unit:8, Offset:19/integer-signed-unit:8, Kind:8/integer-unsigned, Index:16/integer-unsigned>>.

sort_message_keys(A, B) ->
    <<TimeA:19/integer-signed-unit:8, OffsetA:19/integer-signed-unit:8,
      _Kind:8/integer-unsigned, _Index:16/integer-unsigned>> = A,
    <<TimeB:19/integer-signed-unit:8, OffsetB:19/integer-signed-unit:8,
      _Kind:8/integer-unsigned, _Index:16/integer-unsigned>> = B,
    {TimeA, OffsetA} =< {TimeB, OffsetB}.


-spec store_message(msg_kind(), Targets::[pos_integer()], Msg::binary(), #state{}) -> [msg_key()].
store_message(_Kind, [], _Msg, #state{}) ->
    [];
store_message(Kind, [Index | Tail], Msg, State=#state{store=Store}) ->
    MsgKey = mk_message_key(Kind, Index),
    bitcask:put(Store, MsgKey, Msg),
    [MsgKey | store_message(Kind, Tail, Msg, State)].


-spec delete_message(msg_key(), #state{}) -> ok.
delete_message(Key, #state{store=Store}) ->
    bitcask:delete(Store, Key).

-spec lookup_messages(msg_kind(), [pos_integer()], #state{}) -> [{pos_integer(), [msg_key()]}].
lookup_messages(Kind, Indices, #state{store=Store}) ->
    IndexSet = sets:from_list(Indices),
    lager:debug("BitcaskSummaryInfo: ~p", [bitcask:summary_info(Store)]),
    StartTime = os:timestamp(),
    Res = bitcask:fold_keys(Store,
                            fun(#bitcask_entry{key=Key}, Acc) ->
                                    case Key of
                                        <<_Time:19/integer-signed-unit:8, _Offset:19/integer-signed-unit:8,
                                          Kind:8/integer-unsigned, Index:16/integer-unsigned>> ->
                                            case sets:is_element(Index, IndexSet) of
                                                false -> Acc;
                                                true ->
                                                    Keys = case lists:keyfind(Index, 1, Acc) of
                                                               false -> [];
                                                               {Index, L} -> L
                                                           end,
                                                    NewKeys = lists:sort(fun sort_message_keys/2, [Key | Keys]),
                                                    lists:keystore(Index, 1, Acc, {Index, NewKeys})
                                            end;
                                        _ -> Acc
                                    end
                            end,
                            []),
    lager:debug("BitcaskFoldTime: ~p", [timer:now_diff(os:timestamp(), StartTime)]),
    Res.

send_messages([], State=#state{}) ->
    State;
send_messages([{unicast, Index, Msg} | Tail], State=#state{}) ->
    store_message(?OUTBOUND, [Index], Msg, State),
    send_messages(Tail, dispatch_next_messages([Index], State));
send_messages([{multicast, Msg} | Tail], State=#state{workers=Workers, self_index=_SelfIndex}) ->
    Indexes = lists:seq(1, length(Workers)),
    %% lager:debug("~p STORED MULTICAST: ~p", [SelfIndex, base58:binary_to_base58(Key)]),
    store_message(?OUTBOUND, Indexes, Msg, State),
    NewState = dispatch_next_messages(Indexes, State),
    send_messages(Tail, NewState).

%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

store_delete_test() ->
    Store = bitcask:open(lib:nonl(os:cmd("mktemp -d")), [read_write]),
    State = #state{workers=lists:seq(1, 5), store=Store},
    [InKey] = store_message(?INBOUND, [0], <<"hello">>, State),
    ok = delete_message(InKey, State),

    [OutKey1, OutKey3] = store_message(?OUTBOUND, [1, 3], <<"outbound">>, State),
    ?assertEqual([{1, [OutKey1]}], lookup_messages(?OUTBOUND, [1], State)),
    ?assertEqual([{3, [OutKey3]}], lookup_messages(?OUTBOUND, [3], State)),

    ok = delete_message(OutKey1, State),
    not_found = bitcask:get(Store, OutKey1),
    {ok, _} = bitcask:get(Store, OutKey3),
    ?assertEqual([], lookup_messages(?OUTBOUND, [1], State)),

    ok = delete_message(OutKey3, State),
    not_found = bitcask:get(Store, OutKey3),
    ?assertEqual([], lookup_messages(?OUTBOUND, [3], State)),
    ok.

-endif.
