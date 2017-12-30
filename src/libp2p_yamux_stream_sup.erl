-module(libp2p_yamux_stream_sup).

-behavior(supervisor).

-export([init/1]).

init([]) ->
    SupFlags = #{ strategy  => one_for_one},
    {ok, {SupFlags, []}}.
