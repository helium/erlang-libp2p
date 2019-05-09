-module(libp2p_stream_gossip).

-include("pb/libp2p_gossip_pb.hrl").

-behavior(libp2p_stream).

-callback handle_stream_gossip_data(State::any(), Key::string(), Msg::binary()) -> ok.
-callback accept_stream_gossip(State::any(), Muxer::pid() | undefined, Stream::pid()) -> ok | {error, term()}.

%% API
-export([encode/2]).
%% libp2p_framed_stream
-export([init/2,
         handle_packet/4,
         handle_info/3]).


-record(state,
        {
          handler_module :: atom(),
          handler_state :: any()
        }).

%% API
%%
encode(Key, Data) ->
    Msg = #libp2p_gossip_frame_pb{key=Key, data=Data},
    libp2p_gossip_pb:encode_msg(Msg).

%% libp2p_stream
%%

init(server, #{handler_mod := HandlerModule, handler_state := HandlerState}) ->
    %% Catch errors from the handler module in accepting a stream. The
    %% most common occurence is during shutdown of a swarm where
    %% ordering of the shutdown will cause the accept below to crash
    %% noisily in the logs. This catch avoids that noise
    Muxer = libp2p_stream_transport:stream_muxer(),
    case (catch HandlerModule:accept_gossip_stream(HandlerState, Muxer, self())) of
        ok ->
            {ok, #state{handler_module=HandlerModule, handler_state=HandlerState},
             [{packet_spec, [varint]},
              {active, once}]};
        {error, Reason} ->
            %% Stop normally after noticing the reason for the
            %% rejection
            lager:notice("Stopping on accept stream error: ~p", [Reason]),
            {stop, normal};
        Exit={'EXIT', _} ->
            lager:notice("Stopping on accept_stream exit: ~s",
                          [error_logger_lager_h:format_reason(Exit)]),
            {stop, normal}
    end;
init(client, #{handler_mod := HandlerModule, handler_state := HandlerState}) ->
    {ok, #state{handler_module=HandlerModule, handler_state=HandlerState},
     [{packet_spec, [varint]},
      {active, once}]}.

handle_packet(_, _, Data, State=#state{handler_module=HandlerModule,
                                       handler_state=HandlerState}) ->
    #libp2p_gossip_frame_pb{key=Key, data=Bin} =
        libp2p_gossip_pb:decode_msg(Data, libp2p_gossip_frame_pb),

    ok = HandlerModule:handle_gossip_data(HandlerState, Key, Bin),
    {noreply, State, [{active, once}]}.


handle_info(_, {send, Key, Data}, State=#state{}) ->
    Encoded = ?MODULE:encode(Key, Data),
    Packet = libp2p_packet:encode_packet([varint], [byte_size(Encoded)], Encoded),
    {noreply, State, [{send, Packet}]};
handle_info(Kind, Msg, State) ->
    lager:warning("Unhandled ~p info ~p", [Kind, Msg]),
    {noreply, State}.
