-module(libp2p_yamux_stream).

-include("libp2p_yamux.hrl").

-behavior(gen_statem).
-behavior(libp2p_connection).



-record(send_state,
        { window :: non_neg_integer(),
          waiter = undefined :: {from(), binary()} | undefined,
          timer = undefined :: timer() | undefined
         }).

-record(recv_state,
        { window :: non_neg_integer(),
          % Collects window updates to only send updates above a certain threshold
          pending_window = 0 :: non_neg_integer(),
          data = <<>> :: binary(),
          waiter_data = <<>> :: binary(),
          waiter = undefined :: {from(), non_neg_integer()} | undefined,
          timer = undefined :: timer() | undefined
         }).

-record(state,
        { session :: pid(),
          addr_info :: undefined | {string(), string()},
          inert_pid=undefined :: undefined | pid(),
          handler=undefined :: undefined | pid(),
          tid :: ets:tab(),
          stream_id :: libp2p_yamux_session:stream_id(),
          close_state=open :: open | pending,
          max_window = ?DEFAULT_MAX_WINDOW_SIZE :: non_neg_integer(),
          recv_state=#recv_state{} :: #recv_state{},
          send_state=#send_state{} :: #send_state{}
         }).

-type from() :: {pid(), term()}.
-type stream() :: reference().
-type timer() :: undefined | reference().
-type opt() :: {max_window, pos_integer()}.

-export_type([stream/0, opt/0]).

-define(CLOSE_STATE(S), S#state.close_state).
-define(WINDOW_DATA(S), S#state.recv_state#recv_state.data).
-define(WAITER_DATA(S), S#state.recv_state#recv_state.waiter_data).
-define(RECEIVABLE_SIZE(S), (byte_size(?WINDOW_DATA(S)) + byte_size(?WAITER_DATA(S)))).
-define(REMOTE_CLOSED(S), ?CLOSE_STATE(S) == pending).

% gen_statem functions
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

% API
-export([new_connection/1, open_stream/3, receive_stream/3, update_window/3, receive_data/2]).
% libp2p_connection
-export([close/1, close_state/1, send/3, recv/3, acknowledge/2,
         fdset/1, fdclr/1, addr_info/1, controlling_process/2]).

open_stream(Session, TID, StreamID) ->
    % We're opening a stream (client)
    gen_statem:start_link(?MODULE, {Session, TID, StreamID, ?SYN}, []).


receive_stream(Session, TID, StreamID) ->
    % We're receiving/accepting a stream (server)
    gen_statem:start_link(?MODULE, {Session, TID, StreamID, ?ACK}, []).

init({Session, TID, StreamID, Flags}) ->
    erlang:process_flag(trap_exit, true),
    gen_statem:cast(self(), {init, Flags}),
    MaxWindow = libp2p_config:get_opt(libp2p_swarm:opts(TID), [?MODULE, max_window],
                                      ?DEFAULT_MAX_WINDOW_SIZE),
    {ok, connecting, #state{session=Session, stream_id=StreamID, tid=TID, max_window=MaxWindow,
                            send_state=#send_state{window=MaxWindow},
                            recv_state=#recv_state{window=MaxWindow}}}.

callback_mode() -> handle_event_function.

%%
%% Session callbacks, async
%%

update_window(Ref, Flags, Header) ->
    gen_statem:cast(Ref, {update_window, Flags, Header}).

receive_data(Ref, Data) ->
    gen_statem:cast(Ref, {incoming_data, Data}).

% libp2p_connection
%
new_connection(Pid) ->
        libp2p_connection:new(?MODULE, Pid).

statem(Pid, Cmd) ->
    try
        gen_statem:call(Pid, Cmd)
    catch
        exit:{noproc, _} ->
            {error, closed};
        exit:{normal, _} ->
            {error, closed};
        exit:{shutdown, _} ->
            {error, closed}
    end.

close(Pid) ->
    statem(Pid, close).

close_state(Pid) ->
    case statem(Pid, close_state) of
        {error, closed} -> closed;
        R -> R
    end.

send(Pid, Data, Timeout) ->
    statem(Pid, {send, Data, Timeout}).

recv(Pid, Size, Timeout) ->
    statem(Pid, {recv, Size, Timeout}).

acknowledge(_, _) ->
    ok.

fdset(Pid) ->
    statem(Pid, fdset).

fdclr(Pid) ->
    statem(Pid, fdclr).

addr_info(Pid) ->
    statem(Pid, addr_info).

controlling_process(_Pid, _Owner) ->
    {error, unsupported}.


%%
%% State callbacks
%%

handle_event({call, From={Pid, _}}, fdset, _State, Data=#state{recv_state=#recv_state{data= <<>>}}) ->
    %% No existing data, remember the pid for when data arrives
    {keep_state, Data#state{inert_pid=Pid}, {reply, From, ok}};
handle_event({call, From={Pid, _}}, fdset, _State, Data=#state{}) ->
    %% Data exists, go deliver it
    {keep_state, notify_inert(Data#state{inert_pid=Pid}), {reply,From, ok}};
handle_event({call, From}, fdclr, _State, Data=#state{}) ->
    {keep_state, Data#state{inert_pid=undefined}, {reply, From, ok}};


% Connecting
%
handle_event(cast, {init, Flags}, connecting, Data=#state{session=Session, stream_id=StreamID}) when ?FLAG_IS_SET(Flags, ?SYN) ->
    % Client side "open", send out a SYN. The corresponding ACK is
    % received as a window update
    Header=libp2p_yamux_session:header_update(Flags, StreamID, 0),
    case libp2p_yamux_session:send_header(Session, Header) of
        ok -> {next_state, connecting, Data};
        {error, _Reason} -> {stop, normal, Data}
    end;
handle_event(cast, {init, Flags}, connecting, Data=#state{session=Session, stream_id=StreamID, tid=TID}) when ?FLAG_IS_SET(Flags, ?ACK) ->
    %% Starting as a server, fire of an ACK right away
    Header=libp2p_yamux_session:header_update(Flags, StreamID, 0),
    case libp2p_yamux_session:send_header(Session, Header) of
        {error, _Reason} -> {stop, normal, Data};
        ok ->
            %% Start a multistream server to negotiate the handler
            Handlers = libp2p_config:lookup_stream_handlers(TID),
            lager:debug("Starting stream server negotation for ~p: ~p", [StreamID, Handlers]),
            Connection = new_connection(self()),
            AddrInfo = libp2p_session:addr_info(Session),
            {ok, Pid} = libp2p_multistream_server:start_link(StreamID, Connection, Handlers, TID),
            {next_state, established, Data#state{handler=Pid, addr_info=AddrInfo}}
    end;

% Window Updates
%
handle_event(cast, {update_window, Flags, _}, _, Data=#state{}) when ?FLAG_IS_SET(Flags, ?RST) ->
    % The remote closed the stream
    case ?RECEIVABLE_SIZE(Data) > 0 of
        true ->
            %% There is still data pending for a caller, don't stop
            %% this stream yet but mark as pending
            {keep_state, Data#state{close_state=pending}};
        false ->
            %% No more data to deliver, shut down
            {stop, normal, notify_inert(Data)}
    end;
handle_event(cast, {update_window, Flags, _}, connecting, Data=#state{}) when ?FLAG_IS_SET(Flags, ?ACK) ->
    % Client side received an ACK. We have an established connection.
    AddrInfo = libp2p_session:addr_info(Data#state.session),
    {next_state, established, Data#state{addr_info=AddrInfo}};
handle_event(cast, {update_window, _Flags, Header}, established, Data=#state{}) ->
    Data1 = data_send_timeout_cancel(window_receive_update(Header, Data)),
    {keep_state, Data1};

% Sending
%
handle_event({call, From}, {send, _, _}, _State, Data=#state{}) when ?REMOTE_CLOSED(Data) ->
    {keep_state_and_data, {reply, From, {error, closed}}};
handle_event({call, From}, {send, Bin, Timeout}, _State, Data=#state{}) ->
    {keep_state, data_send(From, Bin, Timeout, Data)};
handle_event(info, send_timeout, established, Data=#state{}) ->
    {keep_state, data_send_timeout(Data)};


% Receiving
%
handle_event(cast, {incoming_data, Bin}, _State, Data=#state{stream_id=StreamID}) ->
    case data_incoming(Bin, Data) of
        {error, Error} ->
            lager:error("Failure to handle data for ~p: ~p", [StreamID, Error]),
            {stop, {error, Error}, notify_inert(Data)};
         {ok, D} ->
            {keep_state, (data_recv_timeout_cancel(notify_inert(D)))}
    end;
handle_event(info, recv_timeout, _State, Data=#state{}) ->
    {keep_state, data_recv_timeout(Data)};
handle_event({call, From}, {recv, Size, _}, _State, Data=#state{}) when ?REMOTE_CLOSED(Data) andalso Size > ?RECEIVABLE_SIZE(Data) ->
    % The remote closed and we're being asked for more than we have
    {keep_state_and_data, {reply, From, {error, closed}}};
handle_event({call, From}, {recv, Size, Timeout}, _State, Data0=#state{}) when ?REMOTE_CLOSED(Data0) ->
    % Remote is closed but we have enough cached data to deliver
    Data = data_recv(From, Size, Timeout, Data0),
    case ?RECEIVABLE_SIZE(Data) > 0 of
        % Check if we still have any cached data for future recvs
        true -> {keep_state, Data};
        false -> {stop, normal, notify_inert(Data)}
    end;
handle_event({call, From}, {recv, Size, Timeout}, _State, Data=#state{}) ->
    % Normal open state
    {keep_state, data_recv(From, Size, Timeout, Data)};

% Closing
%
handle_event({call, From}, close, _State, Data=#state{}) when ?REMOTE_CLOSED(Data) ->
    % Remote already closed previously
    {stop_and_reply, normal, {reply, From, ok}, notify_inert(Data)};
handle_event({call, From}, close, _State, Data=#state{}) ->
    % Send RST
    catch close_send(Data),
    {stop_and_reply, normal, {reply, From, ok}, notify_inert(Data)};
handle_event({call, From}, close_state, _, #state{close_state=CloseState}) ->
    {keep_state_and_data, {reply, From, CloseState}};

% Info
%
handle_event(info, {'EXIT', From, Reason}, _State, #state{}) when Reason /= normal ->
    lager:warning("Multistream server ~p exited with reason ~p", [From, Reason]),
    keep_state_and_data;
handle_event(info, {'EXIT', _, _}, _State, #state{})  ->
    keep_state_and_data;
handle_event({call, From}, addr_info, _State, Data=#state{addr_info=undefined, session=Session}) ->
    AddrInfo = libp2p_session:addr_info(Session),
    {keep_state, Data#state{addr_info=AddrInfo}, {reply, From, AddrInfo}};
handle_event({call, From}, addr_info, _State, #state{addr_info=AddrInfo}) ->
    {keep_state_and_data, {reply, From, AddrInfo}};

% Catch all
%
handle_event(EventType, Event, State, #state{stream_id=StreamID}) ->
    lager:error("Unhandled event for ~p (~p) ~p: ~p", [StreamID, State, Event, EventType]),
    keep_state_and_data.


terminate(_Reason, _State, Data=#state{}) ->
    notify_inert(Data).


%%
%% Close
%%

close_send(#state{stream_id=StreamID, session=Session}) ->
    Header = libp2p_yamux_session:header_update(?RST, StreamID, 0),
    libp2p_yamux_session:send_header(Session, Header).

%%
%% Windows
%%

-spec window_send_update(non_neg_integer(), #state{}) -> #state{}.
window_send_update(Delta, State=#state{}) when Delta == 0 ->
    State;
window_send_update(_Delta, State=#state{}) when ?REMOTE_CLOSED(State) ->
    State;
window_send_update(Delta, State=#state{session=Session, stream_id=StreamID, recv_state=#recv_state{window=Window, pending_window=PendingWindow}})
    when PendingWindow + Delta > (Window / 2) ->
    % Send an update if the accumulated window updates are over a certain size
    HeaderDelta = PendingWindow + Delta,
    Header = libp2p_yamux_session:header_update(0, StreamID, HeaderDelta),
    % lager:debug("Sending window update for ~p: ~p", [StreamID, HeaderDelta]),
    libp2p_yamux_session:send_header(Session, Header),
    State#state{recv_state=State#state.recv_state#recv_state{pending_window=0}};
window_send_update(Delta, State=#state{recv_state=#recv_state{pending_window=PendingWindow}}) ->
    State#state{recv_state=State#state.recv_state#recv_state{pending_window=PendingWindow + Delta}}.

-spec window_receive_update(libp2p_yamux_session:header(), #state{}) -> #state{}.
window_receive_update(Header, State=#state{max_window=MaxWindow,
                                           send_state=SendState=#send_state{window=SendWindow}}) ->
    case libp2p_yamux_session:header_length(Header) of
        0 -> State;
        Delta ->
            NewWindow = min(SendWindow + Delta, MaxWindow),
            State#state{send_state=SendState#send_state{window=NewWindow}}
    end.

%%
%% Helpers: Receiving
%%

notify_inert(State=#state{recv_state=#recv_state{waiter=Waiter}}) when Waiter /= undefined ->
    %% If there is a waiter do not notify using inert
    State;
notify_inert(State=#state{inert_pid=NotifyPid}) when NotifyPid == undefined ->
    %% No waiter but nobody to notify either
    State;
notify_inert(State=#state{inert_pid=NotifyPid}) ->
    NotifyPid ! {inert_read, State#state.stream_id, new_connection(self())},
    State#state{inert_pid=undefined}.

-spec data_recv_timeout_cancel(#state{}) -> #state{}.
data_recv_timeout_cancel(State=#state{recv_state=#recv_state{timer=undefined}}) ->
    % No active timer
    State;
data_recv_timeout_cancel(State=#state{recv_state=#recv_state{waiter_data=WaiterData, waiter={_, Size}}})
  when byte_size(WaiterData) < Size ->
    % Not enough data to cancel timer
    State;
data_recv_timeout_cancel(State=#state{recv_state=RecvState=#recv_state{timer=Timer, waiter={From, Size}}}) ->
    RemainingTime = case erlang:cancel_timer(Timer, [{info, true}]) of
                        false -> 0;
                        N -> N
                    end,
    data_recv(From, Size, RemainingTime, State#state{recv_state=RecvState#recv_state{timer=undefined, waiter=undefined}}).

-spec data_recv_timeout(#state{}) -> #state{}.
data_recv_timeout(State=#state{recv_state=#recv_state{waiter=undefined}}) ->
    State;
data_recv_timeout(State=#state{recv_state=RecvState=#recv_state{waiter={From, _}}}) ->
    gen_statem:reply(From, {error, timeout}),
    State#state{recv_state=RecvState#recv_state{timer=undefined, waiter=undefined}}.


-spec data_recv(from(), non_neg_integer(), non_neg_integer() | infinity, #state{}) -> #state{}.
data_recv(From, Size, Timeout, State=#state{recv_state=#recv_state{data=Data, waiter_data=WaiterData, timer=undefined, waiter=undefined}})
  when byte_size(Data) + byte_size(WaiterData) < Size ->
    % lager:debug("Blocking receiver for ~p bytes, timeout ~p, data ~p", [Size, Timeout, byte_size(Data)]),
    Timer =erlang:send_after(Timeout, self(), recv_timeout),
    State1 = window_send_update(byte_size(Data), State),
    State1#state{recv_state=State1#state.recv_state#recv_state{timer=Timer, data= <<>>, waiter_data= <<WaiterData/binary, Data/binary>>, waiter={From, Size}}};

data_recv(From, Size, _Timeout, State=#state{recv_state=RecvState=#recv_state{waiter_data=WaiterData, timer=undefined, waiter=undefined}})
  when byte_size(WaiterData) >= Size ->
    <<FoundData:Size/binary, WaiterRest/binary>> = WaiterData,
    gen_statem:reply(From, {ok, FoundData}),
    State#state{recv_state=RecvState#recv_state{waiter_data=WaiterRest}};

data_recv(From, Size, _Timeout, State=#state{recv_state=#recv_state{data=Data, waiter_data=WaiterData, timer=undefined, waiter=undefined}})
  when ?RECEIVABLE_SIZE(State) >= Size ->
    % Enough data to satisfy request
    TailSize = Size - byte_size(WaiterData),
    <<TailData:TailSize/binary, Rest/binary>> = Data,
    FoundData = <<WaiterData/binary, TailData/binary>>,
    gen_statem:reply(From, {ok, FoundData}),
    % Credit sender for any data pulled from the data window
    DataDelta = max(0, byte_size(Data) - byte_size(Rest)),
    State1 = window_send_update(DataDelta, State),
    State1#state{recv_state=State1#state.recv_state#recv_state{data=Rest, waiter_data= <<>>}}.


-spec data_incoming(binary(), #state{}) -> {ok, #state{}} | {error, term()}.
data_incoming(IncomingData, #state{recv_state=#recv_state{data=Data, window=Window}})
  when byte_size(Data) + byte_size(IncomingData) > Window  ->
    %% Regardless of waiter we check that the incoming data won't push
    %% the window (data) buffer past the window size Validate that
    %% incoming data won't push the data buffer past window size
    {error, {window_exceeded, Window, byte_size(IncomingData), byte_size(Data)}};

data_incoming(IncomingData, State=#state{recv_state=#recv_state{data=Data, window=Window, waiter=undefined}})
  when byte_size(Data) + byte_size(IncomingData) =< Window  ->
    %% No waiter, just add to window buffer
    {ok, State#state{recv_state=State#state.recv_state#recv_state{data= <<Data/binary, IncomingData/binary>>}}};

data_incoming(IncomingData, State=#state{recv_state=#recv_state{data=Data, waiter_data=WaiterData, waiter={_, WaiterSize}}})
  when ?RECEIVABLE_SIZE(State) + byte_size(IncomingData) < WaiterSize ->
    %% Not enough in data and waiter_data to satisfy demand
    %% Push all of it into waiter_data and credit sender
    State1 = window_send_update(byte_size(IncomingData), State),
    {ok, State1#state{recv_state=State1#state.recv_state#recv_state{waiter_data= <<WaiterData/binary, Data/binary, IncomingData/binary>>}}};

data_incoming(IncomingData, State=#state{recv_state=#recv_state{data=Data, waiter_data=WaiterData, waiter={_, WaiterSize}}})
  when ?RECEIVABLE_SIZE(State) + byte_size(IncomingData) >= WaiterSize ->
    %% Enough data to satisfy waiter
    <<WaiterData1:WaiterSize/binary, Rest/binary>>  = <<WaiterData/binary, Data/binary, IncomingData/binary>>,
    DataDelta = max(0, byte_size(Data) - byte_size(Rest)),
    State1 = window_send_update(DataDelta, State),
    {ok, State1#state{recv_state=State1#state.recv_state#recv_state{data=Rest, waiter_data=WaiterData1}}}.


%%
%% Helpers: Sending
%%

-spec data_send_timeout_cancel(#state{}) -> #state{}.
data_send_timeout_cancel(State=#state{send_state=#send_state{timer=undefined}}) ->
    State;
data_send_timeout_cancel(State=#state{send_state=#send_state{window=0}}) ->
    State;
data_send_timeout_cancel(State=#state{send_state=SendState=#send_state{timer=Timer, waiter={From, Data}}}) ->
    RemainingTime = case erlang:cancel_timer(Timer, [{info, true}]) of
                        false -> 0;
                        N -> N
                    end,
    data_send(From, Data, RemainingTime, State#state{send_state=SendState#send_state{timer=undefined, waiter=undefined}}).

-spec data_send_timeout(#state{}) -> #state{}.
data_send_timeout(State=#state{send_state=#send_state{waiter=undefined}}) ->
    State;
data_send_timeout(State=#state{send_state=SendState=#send_state{waiter={From, _}}}) ->
    gen_statem:reply(From, {error, timeout}),
    State#state{send_state=SendState#send_state{timer=undefined, waiter=undefined}}.

-spec data_send(from(), binary(), non_neg_integer(), #state{}) -> #state{}.
data_send(From, <<>>, _Timeout, State=#state{}) ->
    % Empty data for sender, we're done
    gen_statem:reply(From, ok),
    State;
data_send(From, Data, Timeout, State=#state{send_state=SendState=#send_state{window=0, timer=undefined, waiter=undefined}}) ->
    % window empty, create a timeout and the add sender to the waiter list
    Timer = erlang:send_after(Timeout, self(), send_timeout),
    State#state{send_state=SendState#send_state{timer=Timer, waiter={From, Data}}};
data_send(From, Data, Timeout, State=#state{session=Session, stream_id=StreamID, send_state=SendState=#send_state{window=SendWindow}}) ->
    % Send data up to window size
    Window = min(byte_size(Data), SendWindow),
    <<SendData:Window/binary, Rest/binary>> = Data,
    Header = libp2p_yamux_session:header_data(StreamID, 0, Window),
    case libp2p_yamux_session:send_data(Session, Header, SendData) of
        {error, Error} ->
            gen_statem:reply(From, {error, Error}),
            State;
        ok ->
            data_send(From, Rest, Timeout, State#state{send_state=SendState#send_state{window=SendWindow - Window}})
    end.
