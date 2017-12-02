-module(libp2p_session).

-type ref() :: pid().
-type stream_handler() :: {atom(), atom(), [any()]}.

-export_type([ref/0, stream_handler/0]).

-export([ping/1, open/1, close/1, goaway/1, streams/1, addr_info/1]).

-spec ping(ref()) -> pos_integer() | {error, term()}.
ping(Ref) ->
    gen_server:call(Ref, ping, infinity).

-spec open(ref()) -> {ok, libp2p_connection:connection()} | {error, term()}.
open(Ref) ->
    gen_server:call(Ref, open).

-spec close(ref()) -> ok.
close(Ref) ->
    gen_server:stop(Ref).

-spec goaway(ref()) -> ok.
goaway(Ref) ->
    gen_server:call(Ref, goaway).

-spec streams(ref()) -> [ref()].
streams(Ref) ->
    gen_server:call(Ref, streams).

-spec addr_info(ref()) -> {multiaddr:multiaddr(), multiaddr:multiaddr()}.
addr_info(Ref) ->
    gen_server:call(Ref, addr_info).
