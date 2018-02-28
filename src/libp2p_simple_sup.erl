-module(libp2p_simple_sup).

-behavior(supervisor).

-export([init/1]).

init([]) ->
    SupFlags = #{ strategy  => one_for_one},
    {ok, {SupFlags, []}}.
