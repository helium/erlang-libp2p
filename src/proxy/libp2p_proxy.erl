%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Proxy ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy).

-export([
    version/0
    ,add_stream_handler/1
    ,dial_framed_stream/4
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(PROXY_VERSION, "proxy/1.0.0").

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec version() -> string().
version() ->
    ?PROXY_VERSION.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(ets:tab()) -> ok.
add_stream_handler(TID) ->
    libp2p_swarm:add_stream_handler(
        TID
        ,?PROXY_VERSION
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy, self(), TID]}
    ).

%%--------------------------------------------------------------------
%% @doc
%% Dial proxy stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(pid(), string(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(Swarm, Address, Path, Args) ->
    libp2p_swarm:dial_framed_stream(
        Swarm
        ,Address
        ,Path
        ,libp2p_stream_proxy
        ,Args
    ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
