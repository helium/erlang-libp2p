-module(libp2p_group_relcast_server).

-behavio(gen_server).
-behavior(libp2p_ack_stream).

%% API
-export([start_link/4, handle_input/2]).
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

%% libp2p_ack_stream
handle_data(Pid, Ref, Bin) ->
    gen_server:call(Pid, {handle_data, Ref, Bin}).

accept_stream(Pid, MAddr, Connection, Path) ->
    gen_server:call(Pid, {accept_stream, MAddr, Connection, Path}).


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
            DataDir = libp2p_config:data_dir(TID, [groups, GroupID]),
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

handle_call({accept_stream, _MAddr, _Connection, _Path}, _From, State=#state{workers=[]}) ->
    {reply, {error, not_ready}, State};
handle_call({accept_stream, MAddr, Connection, Path}, _From,
            State=#state{self_index=SelfIndex, workers=Workers}) ->
    case lists:keyfind(mk_multiaddr(Path), 1, Workers) of
        false ->
            {reply, {error, not_found}, State};
        {_, SelfIndex, self, _} ->
            {reply, {errror, bad_arg}, State};
        {_, Index, Worker, _} ->
            libp2p_group_worker:assign_stream(Worker, MAddr, Connection),
            {reply, {ok, Index}, State}
    end;
handle_call({handle_data, Index, Msg}, From, State=#state{handler=Handler, handler_state=HandlerState,
                                                          self_index=SelfIndex}) ->
    %% Incoming message, add to queue
    MsgKey = mk_message_key(),
    lager:debug("~p RECEIVED MESSAGE FROM ~p ~p", [SelfIndex, Index, Msg]),
    store_message(?INBOUND, MsgKey, [], Msg, State),
    %% Fast return since the message is stored
    gen_server:reply(From, ok),

    %% Pass on to handler
    case Handler:handle_message(Index, Msg, HandlerState) of
        {NewHandlerState, ok} ->
            delete_message(?INBOUND, MsgKey, Index, State),
            {noreply, State#state{handler_state=NewHandlerState}};
        {NewHandlerState, {send, Messages}} ->
            delete_message(?INBOUND, MsgKey, Index, State),
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
            {noreply, dispatch_next_message(Index, State1)};
        _ ->
            {noreply, State1}
    end;
handle_cast({send_result, {Key, Index}, ok}, State=#state{self_index=SelfIndex}) ->
    %% Sent by group worker. Since we use an ack_stream the message
    %% was acknowledged. Delete the outbound message for the given
    %% index
    lager:debug("~p SEND OK TO ~p: ~p ", [SelfIndex, Index, base58:binary_to_base58(Key)]),
    delete_message(?OUTBOUND, Key, Index, State),
    {noreply, dispatch_next_message(Index, ready_worker(Index, true, State))};
handle_cast({send_result, {Key, Index}, Error}, State=#state{self_index=SelfIndex}) ->
    %% Sent by group worker on error. Instead of looking up the
    %% message by key again we locate the first message that needs to
    %% be sent and dispatch it.
    lager:debug("~p SEND ERROR TO ~p: ~p ERR: ~p ", [SelfIndex, Index, base58:binary_to_base58(Key), Error]),
    {noreply, dispatch_next_message(Index, ready_worker(Index, true, State))};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, Targets}, State=#state{group_id=GroupID, tid=TID}) ->
    ServerPath = lists:flatten(?GROUP_PATH_BASE, GroupID),
    libp2p_swarm:add_stream_handler(libp2p_swarm:swarm(TID), ServerPath,
                                    {libp2p_ack_stream, server,[?MODULE, self()]}),
    {noreply, State#state{workers=start_workers(Targets, State)}};
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
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

-spec dispatch_next_message(pos_integer(), #state{}) -> #state{}.
dispatch_next_message(Index, State=#state{self_index=SelfIndex}) ->
    case lookup_messages(?OUTBOUND, Index, State) of
        [{Key, Msg} | _] ->
            lager:debug("~p DISPATCHING NEXT TO ~p", [SelfIndex, Index]),
            dispatch_message(Index, Key, Msg, State);
        _ -> State
    end.

-spec dispatch_message(pos_integer(), msg_key(), binary(), #state{}) -> #state{}.
dispatch_message(Index, Key, Msg, State=#state{self_index=SelfIndex}) ->
    case lookup_worker(Index, State) of
        {_, SelfIndex, self, true} ->
            %% Dispatch a message to self directly
            Parent = self(),
            lager:debug("~p DISPATCHING TO ~p: ~p", [SelfIndex, Index, base58:binary_to_base58(Key)]),
            spawn(fun() ->
                          Result = handle_data(Parent, Index, Msg),
                          libp2p_group_server:send_result(Parent, {Key, Index}, Result)
                  end),
            ready_worker(Index, false, State);
        {_, Index, _Worker, false} ->
            %% Not ready to dispatch to the given worker
            lager:debug("~p NOT READY TO DISPATCH TO ~p", [SelfIndex, Index]),
            State;
        {_, Index, Worker, true} ->
            lager:debug("~p DISPATCHING TO ~p: ~p", [SelfIndex, Index, base58:binary_to_base58(Key)]),
            libp2p_group_worker:send(Worker, {Key, Index}, Msg),
            ready_worker(Index, false, State)
    end.

mk_multiaddr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_multiaddr(Path) when is_list(Path) ->
    lists:flatten(["/p2p", Path]).

-spec mk_message_key() -> binary().
mk_message_key() ->
    {Time, Offset} = {erlang:monotonic_time(nanosecond), erlang:unique_integer([monotonic])},
    <<Time:19/integer-signed-unit:8, Offset:19/integer-signed-unit:8>>.

sort_message_keys({A, _}, {B, _}) ->
    <<TimeA:19/integer-signed-unit:8, OffsetA:19/integer-signed-unit:8>> = A,
    <<TimeB:19/integer-signed-unit:8, OffsetB:19/integer-signed-unit:8>> = B,
    {TimeA, OffsetA} =< {TimeB, OffsetB}.


-spec set_bit(non_neg_integer(), 0 | 1, binary()) -> binary().
set_bit(Offset, V, Bin) when bit_size(Bin) > Offset ->
    <<A:Offset, _:1, B/bits>> = Bin,
    <<A:Offset, V:1, B/bits>>.

-spec is_bit_set(non_neg_integer(), binary()) -> true | false.
is_bit_set(Offset, Bin) when bit_size(Bin) > Offset ->
    <<_:Offset, V:1, _/bits>> = Bin,
    V == 1.

-spec set_bits([pos_integer()], 0 | 1, bitstring()) -> bitstring().
set_bits([], _V, Acc) ->
    Acc;
set_bits([Index | Tail], V, Acc) ->
    set_bits(Tail, V, set_bit(Index - 1, V, Acc)).


workers_byte_length(#state{workers=Workers}) ->
    Val = length(Workers),
    Multiple = Val div 8,
    case Val rem 8 of
        0 -> Multiple;
        _ -> Multiple + 1
    end.

-spec store_message(msg_kind(), msg_key(), Targets::[pos_integer()] | binary(), Msg::binary(), #state{})
                   -> ok | {error, term()}.
store_message(?INBOUND, Key, _, Msg, #state{store=Store}) ->
    bitcask:put(Store, Key, Msg);
store_message(Kind=?OUTBOUND, Key, Prefix, Msg, #state{store=Store}) when is_binary(Prefix) ->
    PrefixLength = byte_size(Prefix),
    bitcask:put(Store, Key, <<Kind:8/integer-unsigned, Prefix:PrefixLength/binary, Msg/binary>>);
store_message(Kind=?OUTBOUND, Key, Targets, Msg, State=#state{}) ->
    PrefixLength = workers_byte_length(State),
    Prefix = set_bits(Targets, 1, <<0:PrefixLength/unit:8>>),
    store_message(Kind, Key, Prefix, Msg, State).

-spec delete_message(msg_kind(), msg_key(), pos_integer(), #state{}) -> ok.
delete_message(?INBOUND, Key, _Index, #state{store=Store}) ->
    bitcask:delete(Store, Key);
delete_message(Kind=?OUTBOUND, Key, Index, State=#state{store=Store}) ->
    PrefixLength = workers_byte_length(State),
    case bitcask:get(Store, Key) of
        {error, Error} -> error(Error);
        not_found ->
            lager:debug("FAILED TO FIND: ~p", [base58:binary_to_base58(Key)]),
            ok;
        {ok, <<Kind:8/integer-unsigned, Prefix:PrefixLength/binary, Msg/binary>>} ->
            case set_bit(Index - 1, 0, Prefix) of
                <<0:PrefixLength/unit:8>> ->
                    lager:debug("DELETING KEY: ~p", [base58:binary_to_base58(Key)]),
                    bitcask:delete(Store, Key);
                Prefix = <<N:PrefixLength/unit:8>> ->
                    lager:debug("~p DUPLICATE PREFIX ~.2b ~p", [Index, N, base58:binary_to_base58(Key)]),
                    ok;
                NewPrefix= <<N:PrefixLength/unit:8>> ->
                    lager:debug("~p PREFIX ~.2b: ~p", [Index, N, base58:binary_to_base58(Key)]),
                    store_message(Kind, Key, NewPrefix, Msg, State)
            end
    end.

-spec lookup_messages(msg_kind(), pos_integer(), #state{}) -> [{msg_key(), binary()}].
lookup_messages(Kind, Index, State=#state{store=Store}) ->
    PrefixLength = workers_byte_length(State),
    Res = bitcask:fold(Store,
                 fun(Key, Bin, Acc) ->
                         <<Kind:8/integer-unsigned, Prefix:PrefixLength/binary, Msg/binary>> = Bin,
                         case is_bit_set(Index -1, Prefix) of
                             true -> [{Key, Msg} | Acc];
                             false -> Acc
                         end
                 end, []),
    %% sort by key age
    lists:sort(fun sort_message_keys/2, Res).

send_messages([], State=#state{}) ->
    State;
send_messages([{unicast, Index, Msg} | Tail], State=#state{}) ->
    Key = mk_message_key(),
    store_message(?OUTBOUND, Key, [Index], Msg, State),
    send_messages(Tail, dispatch_next_message(Index, State));
send_messages([{multicast, Msg} | Tail], State=#state{workers=Workers, self_index=SelfIndex}) ->
    Key = mk_message_key(),
    Indexes = lists:seq(1, length(Workers)),
    lager:debug("~p STORED MULTICAST: ~p", [SelfIndex, base58:binary_to_base58(Key)]),
    store_message(?OUTBOUND, Key, Indexes, Msg, State),
    NewState = lists:foldr(fun({_, Index, _Pid, _}, AccState) ->
                                   dispatch_next_message(Index, AccState)
                           end, State, Workers),
    send_messages(Tail, NewState).

%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

set_bit_test() ->
    BitSize = 16,
    Bin = <<0:BitSize>>,
    lists:foreach(fun(Offset) ->
                          Expected = 1 bsl (BitSize - 1 - Offset),
                          ?assertEqual(<<Expected:16/integer-unsigned>>,
                                       set_bit(Offset, 1, Bin)),
                          ?assert(is_bit_set(Offset, set_bit(Offset, 1, Bin))),
                          ?assertEqual(Bin, set_bit(Offset, 0, set_bit(Offset, 1, Bin)))
                  end, lists:seq(0, BitSize - 1)),
    ok.

workers_byte_length_test() ->
    ?assertEqual(1, workers_byte_length(#state{workers=lists:seq(1, 7)})),
    ?assertEqual(2, workers_byte_length(#state{workers=lists:seq(1, 9)})),
    ?assertEqual(2, workers_byte_length(#state{workers=lists:seq(1, 16)})),
    ok.

store_delete_test() ->
    Store = bitcask:open(lib:nonl(os:cmd("mktemp -d")), [read_write]),
    State = #state{workers=lists:seq(1, 5), store=Store},
    MsgKey = mk_message_key(),
    ok = store_message(?INBOUND, MsgKey, ignore, <<"hello">>, State),
    ok = delete_message(?INBOUND, MsgKey, 0, State),

    ok = store_message(?OUTBOUND, MsgKey, [1, 3], <<"outbound">>, State),
    ?assertEqual([{MsgKey, <<"outbound">>}], lookup_messages(?OUTBOUND, 1, State)),
    ?assertEqual([{MsgKey, <<"outbound">>}], lookup_messages(?OUTBOUND, 3, State)),

    ok = delete_message(?OUTBOUND, MsgKey, 1, State),
    {ok, _} = bitcask:get(Store, MsgKey),
    ?assertEqual([], lookup_messages(?OUTBOUND, 1, State)),

    ok = delete_message(?OUTBOUND, MsgKey, 3, State),
    not_found = bitcask:get(Store, MsgKey),
    ?assertEqual([], lookup_messages(?OUTBOUND, 3, State)),
    ok.

-endif.
