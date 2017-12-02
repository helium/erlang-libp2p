-module(libp2p_yamux_stream).

-include("libp2p_yamux.hrl").

-behavior(gen_statem).

-record(send_state, {
          window=?DEFAULT_MAX_WINDOW_SIZE :: non_neg_integer(),
          waiter = undefined :: {gen_statem:from(), binary()} | undefined,
          timer = undefined :: timer() | undefined
         }).

-record(recv_state, {
          window=?DEFAULT_MAX_WINDOW_SIZE :: non_neg_integer(),
          data = <<>> :: binary(),
          waiter = undefined :: {gen_statem:from(), non_neg_integer()} | undefined,
          timer = undefined :: timer() | undefined
         }).

-record(state, {
          session :: libp2p_yamux:session(),
          inert_pid=undefined :: undefined | pid(),
          handler=undefined :: undefined | pid(),
          tid :: ets:tab(),
          stream_id :: libp2p_yamux:stream_id(),
          close_state=none :: close_state(),
          recv_state=#recv_state{} :: #recv_state{},
          send_state=#send_state{} :: #send_state{}
         }).

-type close_state() :: local | remote | reset | none.

-type stream() :: reference().
-type timer() :: undefined | reference().


-export_type([stream/0]).

-define(SEND_TIMEOUT, 5000).
-define(RECV_TIMEOUT, 5000).

% gen_statem functions
-export([init/1, callback_mode/0]).

% API
-export([new_connection/1, open_stream/3, receive_stream/3, update_window/3, receive_data/2]).
% libp2p_connection
-export([close/1, send/2, recv/3, acknowledge/2,
         fdset/1, fdclr/1, addr_info/1,
         controlling_process/2]).
% states
-export([handle_event/4]).

open_stream(Session, TID, StreamID) ->
    % We're opening a stream (client)
    {ok, proc_lib:spawn_link(?MODULE, init, [{Session, TID, StreamID, ?SYN}])}.

receive_stream(Session, TID, StreamID) ->
    % We're receiving/accepting a stream (server)
    {ok, proc_lib:spawn_link(?MODULE, init, [{Session, TID, StreamID, ?ACK}])}.

init({Session, TID, StreamID, Flags}) ->
    gen_statem:cast(self(), {init, Flags}),
    gen_statem:enter_loop(?MODULE, [], connecting,
                          #state{session=Session, stream_id=StreamID, tid=TID}).

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

close(Pid) ->
    gen_statem:call(Pid, close).

send(Pid, Data) ->
    gen_statem:call(Pid, {send, Data}).

recv(Pid, Size, Timeout) ->
    gen_statem:call(Pid, {recv, Size}, Timeout).

acknowledge(_, _) ->
    ok.

fdset(Pid) ->
    gen_statem:call(Pid, fdset).

fdclr(Pid) ->
    gen_statem:call(Pid, fdclr).

addr_info(Pid) ->
    gen_statem:call(Pid, addr_info).

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
    ok = libp2p_yamux_session:send(Session, Header),
    {next_state, connecting, Data};
handle_event(cast, {init, Flags}, connecting, Data=#state{session=Session, stream_id=StreamID, tid=TID}) when ?FLAG_IS_SET(Flags, ?ACK) ->
    %% Starting as a server, fire of an ACK right away
    Header=libp2p_yamux_session:header_update(Flags, StreamID, 0),
    ok = libp2p_yamux_session:send(Session, Header),
    % Start a multistream server to negotiate the handler
    Handlers = libp2p_config:lookup_stream_handlers(TID),
    lager:debug("Starting stream server negotation for ~p: ~p", [StreamID, Handlers]),
    Connection = new_connection(self()),
    {ok, Pid} = libp2p_multistream_server:start_link(StreamID, Connection, Handlers, TID),
    {next_state, established, Data#state{handler=Pid}};

% Window Updates
%
handle_event(cast, {update_window, Flags, _}, connecting, Data=#state{}) when ?FLAG_IS_SET(Flags, ?ACK) ->
    % Client side received an ACK. We have an established connection. 
    {next_state, established, Data};
handle_event(cast, {update_window, _, _}, connecting, #state{}) ->
    keep_state_and_data;
handle_event(cast, {update_window, _, _}, closed, #state{}) ->
    keep_state_and_data;
handle_event(cast, {update_window, Flags, Header}, established, Data=#state{}) ->
    {NextState, CloseState} = process_flags(Flags, established, Data),
    Data1 = data_send_timeout_cancel(window_receive_update(Header, Data)),
    {next_state, NextState, Data1#state{close_state=CloseState}};

% Sending
%
handle_event({call, From}, {send, _}, closed, #state{}) ->
    {keep_state_and_data, {reply, From, {error, closed}}};
handle_event({call, From}, {send, _}, _State, #state{close_state=CloseState}) when CloseState == local ->
    {keep_state_and_data, {reply, From, {error, closed}}};
handle_event({call, From}, {send, _}, _State, #state{close_state=CloseState}) when CloseState == reset ->
    {keep_state_and_data, {reply, From, {error, reset}}};
handle_event({call, From}, {send, Bin}, _State, Data=#state{}) ->
    case data_send(From, Bin, Data) of
        {error, Reason} -> {keep_state_and_data, {reply, From, {error, Reason}}};
        D -> {keep_state, D}
    end;
handle_event(info, send_timeout, established, Data=#state{}) ->
    {keep_state, data_send_timeout(Data)};


% Receiving
%
handle_event(cast, {incoming_data, _}, closed, #state{stream_id=StreamID}) ->
    lager:error("Unexpected data in closed state for ~p", [StreamID]),
    {stop, {error, closed}};
handle_event(cast, {incoming_data, Bin}, _State, Data=#state{stream_id=StreamID}) ->
    case data_incoming(Bin, Data) of
        {error, Error} ->
            lager:error("Failure to handle data for ~p: ~p", [StreamID, Error]),
            {stop, {error, Error}};
         D ->
            {keep_state, (data_recv_timeout_cancel(notify_inert(D)))}
    end;
handle_event(info, recv_timeout, established, Data=#state{}) ->
    {keep_state, data_recv_timeout(Data)};
handle_event({call, From}, {recv, _}, closed, #state{}) ->
    {keep_state_and_data, {reply, From, {error, closed}}};
handle_event({call, From}, {recv, Size}, _State, Data=#state{}) ->
    {keep_state, data_recv(From, Size, Data)};

% Closing
%
handle_event({call, From}, close, closed, #state{}) ->
    {keep_state_and_data, {reply, From, ok}};
handle_event({call, From}, close, _State, Data=#state{close_state=CloseState}) when CloseState == local orelse CloseState == remote ->
    % in connecting or established and the stream was half closed, complete it
    close_send(Data),
    {stop_and_reply, normal, {reply, From, ok}};
handle_event({call, From}, close, _State, Data=#state{}) ->
    % in connecting or established, half close the stream
    close_send(Data),
    {keep_state, Data#state{close_state=local}, {reply, From, ok}};

% Info
%
handle_event({call, From}, addr_info, _State, #state{session=Session}) ->
    AddrInfo = libp2p_session:addr_info(Session),
    {keep_state_and_data, {reply, From, AddrInfo}};

% Catch all
%
handle_event(EventType, Event, State, #state{stream_id=StreamID}) ->
    lager:error("Unhandled event for ~p (~p) ~p: ~p", [StreamID, State, Event, EventType]),
    keep_state_and_data.


%%
%% Config
%%

-spec config_get(#state{}, term(), term()) -> term().
config_get(#state{tid=TID}, Key, Default) ->
    case ets:lookup(TID, Key) of
        [] -> Default;
        [Value] -> Value
    end.

-spec process_flags(libp2p_yamux_session:flags(), atom(), #state{}) -> {atom(), close_state()}.
process_flags(Flags, _, #state{}) when ?FLAG_IS_SET(Flags, ?RST) ->
    {closed, reset};
process_flags(Flags, _, #state{close_state=CloseState}) when ?FLAG_IS_SET(Flags, ?FIN) andalso CloseState == local ->
    {closed, reset};
process_flags(Flags, TargetState, #state{}) when ?FLAG_IS_SET(Flags, ?FIN) ->
    {TargetState, remote};
process_flags(_, TargetState, #state{close_state=CloseState}) ->
    {TargetState, CloseState}.

%%
%% Closing
%%

-spec close_send(#state{}) -> ok | {error, term()}.
close_send(#state{stream_id=StreamID, session=Session}) ->
    Header = libp2p_yamux_session:header_update(?FIN, StreamID, 0),
    libp2p_yamux_session:send(Session, Header).

%%
%% Windows
%%

-spec window_send_update(#state{}) -> {ok, #state{}} | {error, term()}.
window_send_update(State=#state{session=Session, stream_id=StreamID,
                                recv_state=RecvState=#recv_state{window=RecvWindow}}) ->
    MaxWindow = config_get(State, {yamux, max_stream_window}, ?DEFAULT_MAX_WINDOW_SIZE),
    case (MaxWindow - RecvWindow) of
        Delta when Delta < (MaxWindow / 2) -> {ok, State};
        Delta ->
            Header = libp2p_yamux_session:header_update(0, StreamID, Delta),
            lager:debug("Sending window update for ~p", [StreamID]),
            case libp2p_yamux_session:send(Session, Header) of
                {error, Error} -> {error, Error};
                ok -> {ok, State#state{recv_state=RecvState#recv_state{window=RecvWindow + Delta}} }
            end
    end.

-spec window_receive_update(libp2p_yamux_session:header(), #state{}) -> #state{}.
window_receive_update(Header, State=#state{stream_id=StreamID, 
                                           send_state=SendState=#send_state{window=SendWindow}}) ->
    lager:debug("Received send window update for ~p", [StreamID]),
    Window = SendWindow + libp2p_yamux_session:header_length(Header),
    State#state{send_state=SendState#send_state{window=Window}}.

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
    NotifyPid ! {inert_read, undefined, undefined},
    State#state{inert_pid=undefined}.

-spec data_recv_timeout_cancel(#state{}) -> #state{}.
data_recv_timeout_cancel(State=#state{recv_state=#recv_state{timer=undefined}}) ->
    State;
data_recv_timeout_cancel(State=#state{recv_state=RecvState=#recv_state{timer=Timer, waiter={From, Size}}}) ->
    erlang:cancel_timer(Timer),
    data_recv(From, Size, State#state{recv_state=RecvState#recv_state{timer=undefined, waiter=undefined}}).

-spec data_recv_timeout(#state{}) -> #state{}.
data_recv_timeout(State=#state{recv_state=RecvState=#recv_state{waiter={From, _}}}) ->
    gen_statem:reply(From, {error, timeout}),
    State#state{recv_state=RecvState#recv_state{timer=undefined, waiter=undefined}}.

-spec data_recv(gen_statem:from(), non_neg_integer(), #state{}) -> #state{}.
data_recv(From, Size, State=#state{recv_state=RecvState=#recv_state{data=Data, timer=undefined, waiter=undefined}}) 
  when byte_size(Data) < Size ->
    Timer =erlang:send_after(?RECV_TIMEOUT, self(), recv_timeout),
    State#state{recv_state=RecvState#recv_state{timer=Timer, waiter={From, Size}}};
data_recv(From, Size, State=#state{recv_state=RecvState=#recv_state{data=Data, timer=undefined, waiter=undefined}}) 
  when byte_size(Data) >= Size ->
    {FoundData, Rest} = case Size of
                            0 -> {Data, <<>>};
                            Value ->
                                <<D:Value/binary, R/binary>> = Data,
                                {D, R}
                        end,
    gen_statem:reply(From, {ok, FoundData}),
    State1 = case window_send_update(State) of 
                 {error, _} -> State; % ignore
                 {ok, S} -> S
             end,
    State1#state{recv_state=RecvState#recv_state{data=Rest}}.

-spec data_incoming(binary(), #state{}) -> #state{} | {error, term()}.
data_incoming(IncomingData, State=#state{recv_state=RecvState=#recv_state{data=Bin, window=Window}}) ->
    IncomingSize = byte_size(IncomingData),
    case Window < IncomingSize of
        true -> {error, {window_exceeded, Window, IncomingSize}};
        false -> State#state{recv_state=RecvState#recv_state{data= <<Bin/binary, IncomingData/binary>>}}
    end.

%%
%% Helpers: Sending
%%

-spec data_send_timeout_cancel(#state{}) -> #state{}.
data_send_timeout_cancel(State=#state{send_state=#send_state{timer=undefined}}) ->
    State;
data_send_timeout_cancel(State=#state{send_state=SendState=#send_state{timer=Timer, waiter={From, Data}}}) ->
    erlang:cancel_timer(Timer),
    data_send(From, Data, State#state{send_state=SendState#send_state{timer=undefined, waiter=undefined}}).

-spec data_send_timeout(#state{}) -> #state{}.
data_send_timeout(State=#state{send_state=SendState=#send_state{waiter={From, _}}}) ->
    gen_statem:reply(From, {error, timeout}),
    State#state{send_state=SendState#send_state{timer=undefined, waiter=undefined}}.

-spec data_send(gen_statem:from(), binary(), #state{}) -> #state{} | {error, term()}.
data_send(From, <<>>, State=#state{}) ->
    % Empty data for sender, we're done
    gen_statem:reply(From, ok),
    State;
data_send(From, Data, State=#state{send_state=SendState=#send_state{window=0, timer=undefined, waiter=undefined}}) ->
    % window empty, create a timeout and the add sender to the waiter list
    Timer = erlang:send_after(?SEND_TIMEOUT, self(), send_timeout),
    State#state{send_state=SendState#send_state{timer=Timer, waiter={From, Data}}};
data_send(From, Data, State=#state{session=Session, stream_id=StreamID, send_state=SendState=#send_state{window=SendWindow}}) ->
    % Send data up to window size
    Window = min(byte_size(Data), SendWindow),
    <<SendData:Window/binary, Rest/binary>> = Data,
    Header = libp2p_yamux_session:header_data(StreamID, 0, Window),
    case libp2p_yamux_session:send(Session, Header, SendData) of
        {error, Reason} -> {error, Reason};
        ok ->
            data_send(From, Rest, State#state{send_state=SendState#send_state{window=SendWindow - Window}})
    end.


