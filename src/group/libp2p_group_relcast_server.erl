-module(libp2p_group_relcast_server).

-behavio(gen_server).
-behavior(libp2p_ack_stream).

%% API
-export([start_link/4]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
%% libp2p_ack_stream
-export([handle_data/3]).

-callback init(ets:tab()) -> {ok, GroupdID::string(), TargetAddrs::[libp2p_crypto:address()], State::any()}
                                 | {error, term()}.

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         client_specs :: [libp2p_group:stream_client_spec()],
         targets :: [string()],
         workers=[] :: [pid()],
         store :: reference(),
         handler :: atom(),
         handler_state :: any()
       }).

-define(INBOUND,  1).
-define(OUTBOUND, 0).

-type msg_kind() :: ?OUTBOUND | ?INBOUND.
-type msg_key() :: binary().

%% libp2p_ack_stream
handle_data(Pid, Ref, Bin) ->
    gen_server:call(Pid, {handle_data, Ref, Bin}).


%% gen_server
%%

start_link(Handler, HandlerState, Sup, TID) ->
    gen_server:start_link(?MODULE, [Handler, HandlerState, Sup, TID], []).

%% bitcask:open does not pass dialyzer correctly so we turn of the
%% using init/1 function and this_peer since it's only used in
%% init_peer/1
-dialyzer({nowarn_function, [init/1]}).

init([Handler, HandlerState, Sup, TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_group_agent(TID),
    Opts = libp2p_swarm:opts(TID, []),
    ClientSpecs = libp2p_group_relcast:get_opt(Opts, stream_clients, []),

    case Handler:init(TID) of
        {ok, GroupID, Addrs, HandlerState} ->
            TargetAddrs = lists:map(fun mk_multiaddr/1, Addrs),
            DataDir = libp2p_config:data_dir(TID, [groups, GroupID]),
            case bitcask:open(DataDir, [read_write]) of
                {error, Reason} -> {stop, {error, Reason}};
                Ref ->
                    self() ! {start_workers, length(TargetAddrs)},
                    {ok, #state{sup=Sup, tid=TID, client_specs=ClientSpecs, targets=TargetAddrs,
                                handler=Handler, handler_state=HandlerState, store=Ref}}
            end;
        {error, Reason} -> {stop, {error, Reason}}
    end.

handle_call(sessions, _From, State=#state{targets=Targets, workers=Workers}) ->
    {reply, lists:zip(Targets, Workers), State};
handle_call({handle_data, Index, Msg}, From, State=#state{handler=Handler, handler_state=HandlerState}) ->
    %% Incoming message, add to queue
    %% Fast return since the message is stored
    MsgKey = mk_message_key(),
    store_message(?INBOUND, MsgKey, [], Msg, State),
    gen_server:reply(From, ok),

    %% Pass on to handler
    case Handler:handle_message(Index, Msg, HandlerState) of
        {NewHandlerState, ok} ->
            delete_message(?INBOUND, MsgKey, Index, State),
            {noreply, State#state{handler_state=NewHandlerState}};
        {NewHandlerState, {send, Messages}} ->
            delete_message(?INBOUND, MsgKey, Index, State),
            %% Send messages
            %% TODO: Store HandlerState
            send_messages(Messages, State),
            {noreply, State#state{handler_state=NewHandlerState}};
        {NewHandlerState, stop, Reason} ->
            {stop, Reason, NewHandlerState}
    end;
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Index, WorkerPid}, State=#state{targets=Targets}) ->
    libp2p_group_worker:assign_target(WorkerPid, lists:nth(Index, Targets)),
    {noreply, State};
handle_cast({send, Bin}, State=#state{}) ->
    send_messages([{multicast, Bin}], State),
    {noreply, State};
handle_cast({send_result, {Key, Index}, _Reason}, State=#state{}) ->
    delete_message(?OUTBOUND, Key, Index, State),
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, Count}, State=#state{sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    Workers = [start_child(WorkerSup, I, State) || I <- lists:seq(1, Count)],
    {noreply, State#state{workers=Workers}};
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.




%% Internal
%%

-spec start_child(pid(), integer(), #state{}) -> pid().
start_child(Sup, Index, #state{tid=TID, client_specs=ClientSpecs}) ->
    ChildSpec = #{ id => make_ref(),
                   start => {libp2p_group_worker, start_link, [Index, ClientSpecs, self(), TID]},
                   restart => permanent
                 },
    {ok, WorkerPid} = supervisor:start_child(Sup, ChildSpec),
    WorkerPid.

mk_multiaddr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_multiaddr(Value) ->
    Value.

-spec mk_message_key() -> binary().
mk_message_key() ->
    {Time, Offset} = {erlang:monotonic_time(nanosecond), erlang:unique_integer([monotonic])},
    <<Time:19/integer-signed-unit:8, Offset:19/integer-signed-unit:8>>.


-spec set_bit(non_neg_integer(), 0 | 1, binary()) -> binary().
set_bit(Offset, V, Bin) when bit_size(Bin) > Offset ->
    <<A:Offset, _:1, B/bits>> = Bin,
    <<A:Offset, V:1, B/bits>>.

-spec set_bits([pos_integer()], 0 | 1, binary()) -> binary().
set_bits([], _V, Acc) ->
    Acc;
set_bits([Index | Tail], V, Acc) ->
    set_bits(Tail, V, set_bit(Index - 1, V, Acc)).

-spec store_message(msg_kind(), msg_key(), Targets::[pos_integer()] | binary(), Msg::binary(), #state{})
                   -> ok | {error, term()}.
store_message(?INBOUND, Key, _, Msg, #state{store=Store}) ->
    bitcask:put(Store, Key, Msg);
store_message(Kind=?OUTBOUND, Key, Prefix, Msg, #state{store=Store}) when is_binary(Prefix) ->
    PrefixLength = bit_size(Prefix),
    bitcask:put(Store, Key, <<Kind:8/integer-unsigned, Prefix:PrefixLength/bits, Msg/binary>>);
store_message(Kind=?OUTBOUND, Key, Targets, Msg, State=#state{}) ->
    PrefixLength = ack_length(State),
    Prefix = set_bits(Targets, 1, <<0:PrefixLength>>),
    store_message(Kind, Key, Prefix, Msg, State).

ack_length(#state{targets=Targets}) ->
    (length(Targets) + 7) band (bnot 7).

%% -spec delete_message(msg_kind(), msg_key(), pos_integer(), #state{}) -> ok.
delete_message(?INBOUND, Key, _Index, #state{store=Store}) ->
    bitcask:delete(Store, Key);
delete_message(Kind=?OUTBOUND, Key, Index, State=#state{store=Store}) ->
    PrefixLength = ack_length(State),
    case bitcask:get(Store, Key) of
        {error, Error} -> error(Error);
        not_found -> error(not_found);
        {ok, <<_Kind:8/integer-unsigned, Prefix:PrefixLength, Msg/binary>>} ->
            case set_bit(Index - 1, 0, Prefix) of
                <<0:PrefixLength>> -> bitcask:delete(Store, Key);
                NewPrefix -> store_message(Kind, Key, NewPrefix, Msg, State)
            end
    end.

send_messages([], #state{}) ->
    ok;
send_messages([{unicast, Index, Msg} | Tail], State=#state{workers=Workers}) ->
    Key = mk_message_key(),
    store_message(?OUTBOUND, Key, [Index], Msg, State),
    libp2p_group_worker:send(lists:nth(Index, Workers), {Key, Index}, Msg),
    send_messages(Tail, State);
send_messages([{multicast, Msg} | Tail], State=#state{workers=Workers}) ->
    Key = mk_message_key(),
    Targets = lists:seq(1, length(Workers)),
    store_message(?OUTBOUND, Key, Targets, Msg, State),
    lists:foreach(fun({Index, Worker}) ->
                          libp2p_group_worker:send(Worker, {Key, Index}, Msg)
                  end, lists:zip(Targets, Workers)),
    send_messages(Tail, State).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

set_bit_test() ->
    BitSize = 16,
    Bin = <<0:BitSize>>,
    lists:foreach(fun(Offset) ->
                          Expected = 1 bsl (BitSize - 1 - Offset),
                          ?assertEqual(<<Expected:16/integer-unsigned>>,
                                       set_bit(Offset, 1, Bin)),
                          ?assertEqual(Bin, set_bit(Offset, 0, set_bit(Offset, 1, Bin)))
                  end, lists:seq(0, BitSize - 1)),
    ok.



-endif.
