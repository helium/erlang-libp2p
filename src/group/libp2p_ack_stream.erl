-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), Msg::binary()) -> ok  | {error, term()}.
-callback accept_stream(State::any(), MAddr::string(), Stream::pid(), Path::string()) ->
    {ok, Ref::any()} | {error, term()}.

%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_send/5]).


-record(state,
        { connection :: libp2p_connection:connection(),
          ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any(),
          send_from=undefined :: term() | undefined,
          msg_seq=0 :: non_neg_integer()
        }).

%% libp2p_framed_stream
%%
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(server, Connection, [Path, AckModule, AckState]) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    case AckModule:accept_stream(AckState, RemoteAddr, self(), Path) of
        {ok, AckRef} ->
            {ok, #state{connection=Connection,
                        ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}};
        {error, Reason} ->
            {stop, {error, Reason}}
    end;
init(client, Connection, [AckRef, AckModule, AckState]) ->
    {ok, #state{connection=Connection,
                ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}}.

handle_data(_Kind, Data, State=#state{send_from=From, ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}) ->
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_data_pb) of
        #libp2p_data_pb{ack=true, seq=_Seq, data=_} when From /= undefined ->
            gen_server:reply(From, ok),
            {noreply, State#state{send_from=undefined}};
        #libp2p_data_pb{ack=false, data=Bin, seq=Seq} ->
            case AckModule:handle_data(AckState, AckRef, Bin) of
                ok ->
                    Ack = #libp2p_data_pb{ack=true, seq=Seq},
                    {noreply, State, libp2p_ack_stream_pb:encode_msg(Ack)};
                {error, Reason} ->
                    {stop, {error, Reason}, State}
            end
    end.

handle_send(_Kind, From, Data, Timeout, State=#state{msg_seq=Seq}) ->
    Msg = #libp2p_data_pb{data=Data, seq=Seq},
    {ok, noreply, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{msg_seq=Seq + 1, send_from=From}}.
