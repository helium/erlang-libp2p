-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), Msg::binary()) -> ok | defer | {error, term()}.
-callback accept_stream(State::any(),
                        Stream::pid(), Path::string()) ->
    {ok, Ref::any()} | {error, term()}.
-callback handle_ack(State::any(), Ref::any(), Ack::ok | defer) -> ok.

%% API
-export([send_ack/1]).
%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_send/5, handle_info/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any(),
          send_from=undefined :: term() | undefined
        }).

%% API
%%

-spec send_ack(pid()) -> ok.
send_ack(Pid) ->
    Pid ! send_ack,
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

handle_data(_Kind, Data, State=#state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState, send_from=From}) ->
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_ack_frame_pb) of
        #libp2p_ack_frame_pb{frame={data, Bin}} ->
            %% Inbound request to handle a message
            case AckModule:handle_data(AckState, AckRef, Bin) of
                {error, Reason} ->
                    {stop, {error, Reason}, State};
                Response ->
                    %% Send back an ok or defer message
                    Ack = #libp2p_ack_frame_pb{frame={ack, Response}},
                    {noreply, State, libp2p_ack_stream_pb:encode_msg(Ack)}
            end;
        #libp2p_ack_frame_pb{frame={ack, Ack}} when From /= undefined  ->
            %% When we receive an ack (ok or defer) from the remote side we
            %% unblock the caller and pass the response back.
            gen_server:reply(From, Ack),
            {noreply, State#state{send_from=undefined}};
        #libp2p_ack_frame_pb{frame={ack, Ack}} ->
            %% When we receive an ack response (ok or defer) from the
            %% remote side without a blocked caller we call the
            %% handler to deal with it.
            AckModule:handle_ack(AckState, AckRef, Ack),
            {noreply, State};
        _Other ->
            {noreply, State}
    end.

handle_send(_Kind, From, Data, Timeout, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{frame={data, Data}},
    {ok, noreply, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{send_from=From}}.

handle_info(_Kind, send_ack, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{frame={ack, ok}},
    {noreply, State, libp2p_ack_stream_pb:encode_msg(Msg)}.
