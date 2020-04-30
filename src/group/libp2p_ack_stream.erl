-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), {Msg::binary(), Seq::pos_integer()}) -> ok.
-callback accept_stream(State::any(),
                        Stream::pid(), Path::string()) ->
    {ok, Ref::any()} | {error, term()}.
-callback handle_ack(State::any(), Ref::any(), Seq::[pos_integer()], Reset::boolean()) -> ok.

%% API
-export([send_ack/3]).
%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_send/5, handle_info/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any()
        }).

-define(ACK_STREAM_TIMEOUT, timer:minutes(5)).

%% API
%%

-spec send_ack(pid(), pos_integer(), boolean()) -> ok.
send_ack(Pid, Seq, Reset) ->
    Pid ! {send_ack, Seq, Reset},
    ok.

%% libp2p_framed_stream
%%
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(server, Connection, [Path, AckModule, AckState | _]) ->
    %% Catch errors from the handler module since the handling group
    %% may have already stopped or crashed.
    lager:info("INITIATING SERVER WITH ~p ~p ~p",[Path, AckModule, AckState]),

    case (catch AckModule:accept_stream(AckState, self(), Path)) of
        {ok, AckRef} ->
            libp2p_connection:set_idle_timeout(Connection, ?ACK_STREAM_TIMEOUT),
            {ok, #state{connection=Connection,
                        ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}};
        {error, Reason} ->
            {stop, {error, Reason}};
        {'EXIT', {noproc, _}} ->
            %% Handle noproc silently since it's pretty common for a
            %% relcast group to have gone away
            {stop, normal};
        Exit={'EXIT', _} ->
            lager:warning("Stopping on accept_stream exit: ~s",
                          [error_logger_lager_h:format_reason(Exit)]),
            {stop, normal}
    end;
init(client, Connection, [AckRef, AckModule, AckState | _]) ->
    lager:info("INITIATING CLIENT WITH ~p ~p ~p",[AckRef, AckModule, AckState]),
    libp2p_connection:set_idle_timeout(Connection, ?ACK_STREAM_TIMEOUT),
    {ok, #state{connection=Connection,
                ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}}.

handle_data(_Kind, Data, State=#state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}) ->
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_ack_frame_pb) of
        #libp2p_ack_frame_pb{messages=Bin, seqs=Seq} when Bin /= [] ->
            %% Inbound request to handle a message
            lager:info("ACK MODULE ~p",[AckModule]),
            AckModule:handle_data(AckState, AckRef, lists:zip(Seq, Bin)),
            {noreply, State};
        #libp2p_ack_frame_pb{seqs=Seq, reset=Reset} ->
            %% When we receive an ack response from the remote side we
            %% call the handler to deal with it.
            AckModule:handle_ack(AckState, AckRef, Seq, Reset == true),
            {noreply, State};
        _Other ->
            lager:info("other ~p", [_Other]),
            {noreply, State}
    end.

handle_send(_Kind, From, Msgs, Timeout, State=#state{}) when is_list(Msgs) ->
    {Seqs, Data} = lists:unzip(Msgs),
    Msg = #libp2p_ack_frame_pb{messages=Data, seqs=Seqs},
    {ok, {reply, From, pending}, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{}};
handle_send(_Kind, From, {Data, Seq}, Timeout, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{messages=[Data], seqs=[Seq]},
    {ok, {reply, From, pending}, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{}}.

handle_info(_Kind, {send_ack, Seq, Reset}, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{seqs=Seq, reset=Reset},
    {noreply, State, libp2p_ack_stream_pb:encode_msg(Msg)}.
