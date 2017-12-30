-module(libp2p_session).

-type stream_handler() :: {atom(), atom(), [any()]}.

-export_type([stream_handler/0]).

-export([ping/1, open/1, close/1, goaway/1, streams/1, addr_info/1]).

-spec ping(pid()) -> pos_integer() | {error, term()}.
ping(Pid) ->
    gen_server:call(Pid, ping, infinity).

-spec open(pid()) -> {ok, libp2p_connection:connection()} | {error, term()}.
open(Pid) ->
    gen_server:call(Pid, open).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:stop(Pid).

-spec goaway(pid()) -> ok.
goaway(Pid) ->
    gen_server:call(Pid, goaway).

-spec streams(pid()) -> [pid()].
streams(Pid) ->
    gen_server:call(Pid, streams).

-spec addr_info(pid()) -> {multiaddr:multiaddr(), multiaddr:multiaddr()}.
addr_info(Pid) ->
    gen_server:call(Pid, addr_info).
