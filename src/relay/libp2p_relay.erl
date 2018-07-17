%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay).

-export([
    add_stream_handler/1
    ,dial/3
    ,stream/3
]).

-define(RELAY_VERSION, "relay/1.0.0").

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
-spec dial(pid(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial(Swarm, Address, Args) ->
    case libp2p_swarm:dial(Swarm, Address, ?RELAY_VERSION) of
        {ok, Conn} ->
            Args1 = [
                {swarm, Swarm}
            ],
            libp2p_framed_stream:client(libp2p_stream_relay, Conn, Args ++ Args1);
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% Dial relay stream
%% @end
%%--------------------------------------------------------------------
-spec stream(pid(), string(), pid()) -> {ok, pid()} | {error, term()} | ignore.
stream(SessionPid, Addr, TID) ->
    Swarm = libp2p_swarm:swarm(TID),
    libp2p_session:dial_framed_stream(
        ?RELAY_VERSION
        ,SessionPid
        ,libp2p_stream_relay
        ,[{swarm, Swarm}, {relay, Addr}]
    ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
