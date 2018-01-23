-module(test_util).

-export([setup/0, setup_swarms/0, setup_swarms/1, teardown_swarms/1,
         wait_until/3]).

setup() ->
    application:ensure_all_started(ranch),
    %% application:ensure_all_started(lager),
    %% lager:set_loglevel(lager_console_backend, debug),
    %% lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    ok.

setup_swarms(0, Acc) ->
    Acc;
setup_swarms(N, Acc) ->
    setup_swarms(N - 1, [begin
                             {ok, Pid} = libp2p_swarm:start(0),
                             Pid
                         end | Acc]).

setup_swarms(N) when N >= 1 ->
    setup(),
    setup_swarms(N, []).

setup_swarms() ->
    setup_swarms(2).

teardown_swarms(Swarms) ->
    lists:map(fun libp2p_swarm:stop/1, Swarms).


wait_until(Fun) ->
    wait_until(Fun, 10, 1000).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.
