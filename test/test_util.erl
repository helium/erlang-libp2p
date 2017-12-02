-module(test_util).

-export([setup_swarms/0, teardown_swarms/1]).

setup_swarms() ->
    application:ensure_all_started(ranch),
    %% application:ensure_all_started(lager),
    S1 = libp2p_swarm:start(0),
    S2 = libp2p_swarm:start(0),
    [S1, S2].

teardown_swarms(Swarms) ->
    lists:map(fun libp2p_swarm:stop/1, Swarms).
