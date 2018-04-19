-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(any(), term(), binary()) -> ok  | {error, term()}.
-callback handle_ack(any(), term()) -> ok.

%%
-export([send/2]).

%% libp2p_framed_stream
-export([init/3, handle_data/3, handle_info/3]).

-record(state,
        { ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any()
        }).

init(server, _Connection, [_Path, AckRef, AckModule, AckState]) ->
    {ok, #state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}};
init(client, _Connection, [AckRef, AckModule, AckState]) ->
    {ok, #state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}}.

handle_data(_, Data, State=#state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}) ->
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_data_pb) of
        #libp2p_data_pb{ack=false, data=Bin} ->
            case AckModule:handle_data(AckState, AckRef, Bin) of
                ok ->
                    Ack = #libp2p_data_pb{ack=true},
                    {resp, libp2p_ack_stream_pb:encode_msg(Ack), State};
                {error, Reason} ->
                    {stop, {error, Reason}, State}
            end;
        #libp2p_data_pb{ack=true} ->
            AckModule:handle_ack(AckState, AckRef)
    end.

handle_info(_, {send, Data}, State=#state{}) ->
    Msg = #libp2p_data_pb{data=Data},
    {resp, libp2p_ack_stream_pb:encode_msg(Msg), State}.


-spec send(pid(), binary()) ->ok.
send(Pid, Bin) ->
    Pid ! {send, Bin},
    ok.
