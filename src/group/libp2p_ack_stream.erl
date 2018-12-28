-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), {Msg::binary(), Seq::pos_integer()}) -> ok.
-callback accept_stream(State::any(),
                        Stream::pid(), Path::string()) ->
    {ok, Ref::any()} | {error, term()}.
-callback handle_ack(State::any(), Ref::any(), Seq::pos_integer()) -> ok.

%% API
-export([send_ack/2]).
%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_send/5, handle_info/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any()
        }).

%% API
%%

-spec send_ack(pid(), pos_integer()) -> ok.
send_ack(Pid, Seq) ->
    Pid ! {send_ack, Seq},
    ok.

%% libp2p_framed_stream
%%
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(server, Connection, [Path, AckModule, AckState]) ->
    case AckModule:accept_stream(AckState, self(), Path) of
        {ok, AckRef} ->
            {ok, #state{connection=Connection,
                        ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}};
        {error, Reason} ->
            {stop, {error, Reason}}
    end;
init(client, Connection, [AckRef, AckModule, AckState]) ->
    {ok, #state{connection=Connection,
                ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}}.

handle_data(_Kind, Data, State=#state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}) ->
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_ack_frame_pb) of
        #libp2p_ack_frame_pb{data=Bin, seq=Seq} when Bin /= <<>> ->
            %% Inbound request to handle a message
            AckModule:handle_data(AckState, AckRef, {Bin, Seq}),
            {noreply, State};
        #libp2p_ack_frame_pb{seq=Seq} ->
            %% When we receive an ack response from the remote side we
            %% call the handler to deal with it.
            AckModule:handle_ack(AckState, AckRef, Seq),
            {noreply, State};
        _Other ->
            {noreply, State}
    end.

handle_send(_Kind, From, {Data, Seq}, Timeout, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{data=Data, seq=Seq},
    {ok, {reply, From, pending}, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{}}.

handle_info(_Kind, {send_ack, Seq}, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{seq=Seq},
    {noreply, State, libp2p_ack_stream_pb:encode_msg(Msg)}.
