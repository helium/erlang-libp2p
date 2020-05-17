-module(libp2p_gossip_stream).

-include("gossip.hrl").
-include("pb/libp2p_gossip_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), StreamPid::pid(), Key::string(), Msg::binary()) -> ok.
-callback accept_stream(State::any(),
                        Session::pid(),
                        Stream::pid(),
                        Path::string()) -> ok | {error, term()}.

%% API
-export([encode/2, encode/3]).
%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_info/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          handler_module :: atom(),
          handler_state :: any(),
          path :: any(),
          reply_ref=make_ref() :: reference(),
          global_bloom :: forgetful_bloom:bloom(),
          local_bloom :: forgetful_bloom:bloom()
        }).

%% API
%%
encode(Key, Data) ->
    %% replies are routed via encode/2 from the gossip server
    lager:debug("gossip encoding, no path: ~p",[]),
    Msg = #libp2p_gossip_frame_pb{key=Key, data=Data},
    libp2p_gossip_pb:encode_msg(Msg).

encode(Key, Data, Path) ->
    lager:debug("gossip encoding for path: ~p",[Path]),
    Msg = #libp2p_gossip_frame_pb{key=Key, data=apply_path_encode(Path, Data)},
    libp2p_gossip_pb:encode_msg(Msg).

%% libp2p_framed_stream
%%
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, _Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, Args).

init(server, Connection, [Path, HandlerModule, HandlerState, Bloom]) ->
    lager:debug("initiating server with path ~p", [Path]),
    {ok, Session} = libp2p_connection:session(Connection),
    %% Catch errors from the handler module in accepting a stream. The
    %% most common occurence is during shutdown of a swarm where
    %% ordering of the shutdown will cause the accept below to crash
    %% noisily in the logs. This catch avoids that noise
    case (catch HandlerModule:accept_stream(HandlerState, Session, self(), Path)) of
        ok ->
            {ok, LocalBloom} = forgetful_bloom:new_for_fp_rate(1000, 1.0e-7, 3, 1000),
            {ok, #state{connection=Connection,
                        handler_module=HandlerModule,
                        handler_state=HandlerState,
                        global_bloom=Bloom,
                        local_bloom=LocalBloom,
                        path=Path}};
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
init(client, Connection, [Path, HandlerModule, HandlerState, Bloom]) ->
    lager:debug("initiating client with path ~p", [Path]),
    {ok, LocalBloom} = forgetful_bloom:new_for_fp_rate(1000, 1.0e-7, 3, 1000),
    {ok, #state{connection=Connection,
                handler_module=HandlerModule,
                handler_state=HandlerState,
                global_bloom=Bloom,
                local_bloom=LocalBloom,
                path=Path}}.

handle_data(_Role, Data, State=#state{handler_module=HandlerModule,
                                  handler_state=HandlerState,
                                  local_bloom=LocalBloom,
                                  global_bloom=GlobalBloom,
                                  path=Path}) ->
    #libp2p_gossip_frame_pb{key=Key, data=Bin} =
        libp2p_gossip_pb:decode_msg(Data, libp2p_gossip_frame_pb),
    lager:debug("gossip received for handler ~p and key ~p via path ~p with payload ~p",[HandlerModule, Key, Path, Bin]),
    Decoded = apply_path_decode(Path, Bin),
    %% use or here because we don't want to short circuit
    case forgetful_bloom:set(LocalBloom, {Key, Decoded}) or forgetful_bloom:set(GlobalBloom, {Key, Decoded}) of
        true ->
            %% TODO this might mess with ARP
            %% either we've already sent this to this peer, they've sent it to us, or 
            %% someone else has sent it to us. In any case there's no need to handle it.
            ok;
        false ->
            ok = HandlerModule:handle_data(HandlerState, self(), Key,
                                           {Path, Decoded})
    end,
    {noreply, State}.

handle_info(server, {Ref, AcceptResult}, State=#state{reply_ref=Ref}) ->
    case AcceptResult of
        ok ->
            erlang:demonitor(Ref, [flush]),
            {noreply, State};
        {error, too_many} ->
            {stop, normal, State};
        {error, Reason} ->
            lager:warning("Stopping on accept stream error: ~p", [Reason]),
            {stop, {error, Reason}, State}
    end;
handle_info(server, {'DOWN', Ref, process, _, Reason}, State=#state{reply_ref=Ref}) ->
    %% gossip server died while we were waiting for accept result
    {stop, Reason, State};
handle_info(_, _, State) ->
    {noreply, State}.

apply_path_encode(?GROUP_PATH_V1, Data)->
    lager:debug("not compressing for path ~p..",[?GROUP_PATH_V1]),
    Data;
apply_path_encode(?GROUP_PATH_V2, Data)->
    lager:debug("compressing for path ~p..",[?GROUP_PATH_V2]),
    zlib:compress(Data);
apply_path_encode(_UnknownPath, Data)->
    lager:debug("not compressing for path ~p..",[_UnknownPath]),
    Data.
apply_path_decode(?GROUP_PATH_V1, Data)->
    lager:debug("not decompressing for path ~p..",[?GROUP_PATH_V1]),
    Data;
apply_path_decode(?GROUP_PATH_V2, Data)->
    lager:debug("decompressing for path ~p..",[?GROUP_PATH_V2]),
    zlib:uncompress(Data);
apply_path_decode(_UnknownPath, Data)->
    lager:debug("not decompressing for path ~p..",[_UnknownPath]),
    Data.

