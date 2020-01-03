-module(libp2p_gossip_stream).

-include("pb/libp2p_gossip_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), StreamPid::pid(), Key::string(), Msg::binary()) -> ok.
-callback accept_stream(State::any(),
                        Session::pid(),
                        Stream::pid()) -> ok | {error, term()}.

%% API
-export([encode/2]).
%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          handler_module :: atom(),
          handler_state :: any()
        }).

%% API
%%
encode(Key, Data) ->
    Msg = #libp2p_gossip_frame_pb{key=Key, data=Data},
    libp2p_gossip_pb:encode_msg(Msg).

%% libp2p_framed_stream
%%
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, _Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, Args).

init(server, Connection, [HandlerModule, HandlerState]) ->
    {ok, Session} = libp2p_connection:session(Connection),
    %% Catch errors from the handler module in accepting a stream. The
    %% most common occurence is during shutdown of a swarm where
    %% ordering of the shutdown will cause the accept below to crash
    %% noisily in the logs. This catch avoids that noise
    case (catch HandlerModule:accept_stream(HandlerState, Session, self())) of
        ok -> {ok, #state{connection=Connection,
                          handler_module=HandlerModule,
                          handler_state=HandlerState}};
        {error, too_many} ->
            {stop, normal};
        {error, Reason} ->
            lager:warning("Stopping on accept stream error: ~p", [Reason]),
            {stop, {error, Reason}};
        Exit={'EXIT', _} ->
            lager:warning("Stopping on accept_stream exit: ~s",
                          [error_logger_lager_h:format_reason(Exit)]),
            {stop, normal}
    end;
init(client, Connection, [HandlerModule, HandlerState]) ->
    {ok, #state{connection=Connection,
                handler_module=HandlerModule,
                handler_state=HandlerState}}.

handle_data(_, Data, State=#state{handler_module=HandlerModule,
                                  handler_state=HandlerState}) ->
    #libp2p_gossip_frame_pb{key=Key, data=Bin} =
        libp2p_gossip_pb:decode_msg(Data, libp2p_gossip_frame_pb),

    ok = HandlerModule:handle_data(HandlerState, self(), Key, Bin),
    {noreply, State}.
