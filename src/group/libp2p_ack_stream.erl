-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), Msg::binary()) -> ok  | {error, term()}.
-callback accept_stream(State::any(), Connection::libp2p_connection:connection(), Path::string()) ->
    {ok, Ref::any()} | {error, term()}.

%% API
-export([server/4, send/3]).
%% libp2p_framed_stream
-export([init/3, handle_data/3, handle_call/4, handle_info/3]).

-record(state,
        { ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any(),
          send_timer=undefined :: undefined | reference(),
          send_from=undefined :: undefined | term()
        }).

%% API
%%

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

send(Pid, Data, Timeout) ->
    gen_server:call(Pid, {send, Data, Timeout}).

init(server, Connection, [Path, AckModule, AckState]) ->
    case AckModule:accept_stream(AckState, Connection, Path) of
        {ok, AckRef} ->
            {ok, #state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}};
        {error, Reason} ->
            {stop, {error, Reason}}
    end;
init(client, _Connection, [AckRef, AckModule, AckState]) ->
    {ok, #state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}}.

handle_data(_, Data, State=#state{}) ->
    handle_message(libp2p_ack_stream_pb:decode_msg(Data, libp2p_data_pb), State).

handle_call(_, {send, Data, Timeout}, From, State=#state{}) ->
    Msg = #libp2p_data_pb{data=Data},
    Timer = erlang:send_after(Timeout, self(), send_timeout),
    {noreply, State#state{send_from=From, send_timer=Timer}, libp2p_ack_stream_pb:encode_msg(Msg)};
handle_call(Kind, Msg, _From, State=#state{}) ->
    lager:warning("Unhandled ~p call ~p", [Kind, Msg]),
    {noreply, State}.

handle_info(_, send_timeout, State=#state{send_from=From}) ->
    gen_server:reply(From, {error, timeout}),
    {noreply, State#state{send_timer=undefined}};
handle_info(Kind, Msg, State=#state{}) ->
    lager:warning("Unhandled ~p info ~p", [Kind, Msg]),
    {noreply, State}.



%% Internal
%%

-spec cancel_timer(undefined | reference()) -> undefined.
cancel_timer(undefined) ->
    undefined;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    undefined.

-spec handle_message(#libp2p_data_pb{}, #state{}) -> libp2p_framed_stream:handle_data_result().
handle_message(#libp2p_data_pb{ack=true, data=_}, State=#state{send_from=From, send_timer=Timer}) ->
    gen_server:reply(From, ok),
    {noreply, State#state{send_from=undefined, send_timer=cancel_timer(Timer)}};
handle_message(#libp2p_data_pb{ack=false, data=Bin},
               State=#state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}) ->
    case AckModule:handle_data(AckState, AckRef, Bin) of
        ok ->
            Ack = #libp2p_data_pb{ack=true},
            {noreply, State, libp2p_ack_stream_pb:encode_msg(Ack)};
        {error, Reason} ->
            {stop, {error, Reason}, State}
    end.
