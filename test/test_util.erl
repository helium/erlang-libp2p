-module(test_util).

-export([setup_swarms/0, setup_swarms/1, teardown_swarms/1]).

setup_swarms(0, Acc) ->
    Acc;
setup_swarms(N, Acc) ->
    setup_swarms(N - 1, [libp2p_swarm:start(0) | Acc]).

setup_swarms(N) when N >= 1 ->
    application:ensure_all_started(ranch),
    %% application:ensure_all_started(lager),
    %% lager:set_loglevel(lager_console_backend, debug),
    %% lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    setup_swarms(N, []).

setup_swarms() ->
    setup_swarms(2).

teardown_swarms(Swarms) ->
    lists:map(fun libp2p_swarm:stop/1, Swarms).
