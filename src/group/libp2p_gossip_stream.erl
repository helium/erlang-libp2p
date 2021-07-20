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
          bloom :: bloom_nif:bloom(),
          reply_ref=make_ref() :: reference()
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
    HandlerModule:accept_stream(HandlerState, Session, self(), Path),
    {ok, #state{connection=Connection,
                handler_module=HandlerModule,
                handler_state=HandlerState,
                bloom=Bloom,
                path=Path}};

init(client, Connection, [Path, HandlerModule, HandlerState, Bloom]) ->
    lager:debug("initiating client with path ~p", [Path]),
    {ok, #state{connection=Connection,
                handler_module=HandlerModule,
                handler_state=HandlerState,
                bloom=Bloom,
                path=Path}}.

handle_data(_Role, Data, State=#state{handler_module=HandlerModule,
                                  handler_state=HandlerState,
                                  bloom=Bloom,
                                  path=Path}) ->
    #libp2p_gossip_frame_pb{key=Key, data=Bin} =
        libp2p_gossip_pb:decode_msg(Data, libp2p_gossip_frame_pb),
    lager:debug("gossip received for handler ~p and key ~p via path ~p with payload ~p",[HandlerModule, Key, Path, Bin]),
    DecodedData = apply_path_decode(Path, Bin),
    case bloom:check(Bloom, {in, DecodedData}) of
        true ->
            ok;
        false ->
            %% TODO if we knew this connections's peer/target address
            %% we could do a second bloom:set to allow tracking where we
            %% received this data from
            bloom:set(Bloom, {in, DecodedData}),
            ok = HandlerModule:handle_data(HandlerState, self(), Key,
                                           {Path, DecodedData})
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

