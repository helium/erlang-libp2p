%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay).

-export([
    version/0
    ,add_stream_handler/1
    ,dial_framed_stream/3
]).

-define(RELAY_VERSION, "relay/1.0.0").

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec version() -> string().
version() ->
    ?RELAY_VERSION.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(ets:tab()) -> ok.
add_stream_handler(TID) ->
    libp2p_swarm:add_stream_handler(
        TID
        ,?RELAY_VERSION
        ,{libp2p_framed_stream, server, [libp2p_stream_relay, self(), TID]}
    ).

%%--------------------------------------------------------------------
%% @doc
%% Dial relay stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(pid(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(Swarm, Address, Args) ->
    case libp2p_swarm:dial(Swarm, Address, ?RELAY_VERSION) of
        {ok, Conn} ->
            Args1 = [
                {swarm, Swarm}
            ],
            libp2p_framed_stream:client(libp2p_stream_relay, Conn, Args ++ Args1);
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
