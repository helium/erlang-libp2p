-module(test_util).

-export([setup/0, setup_swarms/0, setup_swarms/1, teardown_swarms/1,
         wait_until/1, wait_until/3, rm_rf/1]).

setup() ->
    rm_rf(libp2p_config:data_dir()),
    application:ensure_all_started(ranch),
    %% application:ensure_all_started(lager),
    %% lager:set_loglevel(lager_console_backend, debug),
    %% lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    ok.

setup_swarms(0, Acc) ->
    Acc;
setup_swarms(N, Acc) ->
    setup_swarms(N - 1, [begin
                             Name = list_to_atom("swarm" ++ integer_to_list(erlang:monotonic_time())),
                             {ok, Pid} = libp2p_swarm:start(Name),
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
    wait_until(Fun, 40, 100).

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


-spec rm_rf(file:filename()) -> ok.
rm_rf(Dir) ->
    Paths = filelib:wildcard(Dir ++ "/**"),
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
    ok = lists:foreach(fun file:delete/1, Files),
    Sorted = lists:reverse(lists:sort(Dirs)),
    ok = lists:foreach(fun file:del_dir/1, Sorted),
    file:del_dir(Dir).
