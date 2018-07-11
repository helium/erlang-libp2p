-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), Msg::binary()) -> ok | defer | {error, term()}.
-callback accept_stream(State::any(), MAddr::string(), Stream::pid(), Path::string()) ->
    {ok, Ref::any()} | {error, term()}.

%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_send/5, handle_cast/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any(),
          send_from=undefined :: term() | undefined
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
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_ack_frame_pb) of
        #libp2p_ack_frame_pb{frame={data, Bin}} ->
            %% Inbound request to handle a message
            case AckModule:handle_data(AckState, AckRef, Bin) of
                defer ->
                    %% Send back a defer message to keep the sender
                    %% waiting for the final ack.
                    Ack = #libp2p_ack_frame_pb{frame={ack, defer}},
                    {noreply, State, libp2p_ack_stream_pb:encode_msg(Ack)};
                ok ->
                    %% Handler is ok with the message. Ack back to the
                    %% sender.
                    Ack = #libp2p_ack_frame_pb{frame={ack, ack}},
                    {noreply, State, libp2p_ack_stream_pb:encode_msg(Ack)};
                {error, Reason} ->
                    {stop, {error, Reason}, State}
            end;
        #libp2p_ack_frame_pb{frame={ack, defer}} ->
            %% When we receive a defer we do _not_ reply back to teh
            %% original caller. This way we block the sender until the
            %% actual ack is received
            {noreply, State};
        #libp2p_ack_frame_pb{frame={ack, ack}} when From /= undefined  ->
            gen_server:reply(From, ok),
            {noreply, State#state{send_from=undefined}};
        _Other ->
            {noreply, State}
    end.

handle_send(_Kind, From, Data, Timeout, State=#state{send_from=undefined}) ->
    Msg = #libp2p_ack_frame_pb{frame={data, Data}},
    {ok, noreply, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{send_from=From}}.


handle_cast(_Kind, ack, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{frame={ack, ack}},
    {noreply, State, libp2p_ack_stream_pb:encode_msg(Msg)}.
