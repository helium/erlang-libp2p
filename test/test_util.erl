-module(test_util).

-export([setup_swarms/0, setup_swarms/1, teardown_swarms/1]).

setup_swarms(0, Acc) ->
    Acc;
setup_swarms(N, Acc) ->
    setup_swarms(N - 1, [libp2p_swarm:start(0) | Acc]).

setup_swarms(N) when N >= 1 ->
    application:ensure_all_started(ranch),
    setup_swarms(N, []).

setup_swarms() ->
    setup_swarms(2).

teardown_swarms(Swarms) ->
    lists:map(fun libp2p_swarm:stop/1, Swarms).
