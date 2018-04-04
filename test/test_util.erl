-module(test_util).

-export([setup/0, setup_swarms/0, setup_swarms/2, teardown_swarms/1,
         wait_until/1, wait_until/3, rm_rf/1, foreach/1, with/1, foreachx/1]).

setup() ->
    application:ensure_all_started(ranch),
    %% application:ensure_all_started(lager),
    %% lager:set_loglevel(lager_console_backend, debug),
    %% lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    ok.

setup_swarms(0, _Opts, Acc) ->
    Acc;
setup_swarms(N, Opts, Acc) ->
    setup_swarms(N - 1, Opts,
                 [begin
                      Name = list_to_atom("swarm" ++ integer_to_list(erlang:unique_integer([monotonic]))),

                      {ok, Pid} = libp2p_swarm:start(Name, Opts),
                      ok = libp2p_swarm:listen(Pid, "/ip4/0.0.0.0/tcp/0"),
                      Pid
                  end | Acc]).

setup_swarms(N, Opts) when N >= 1 ->
    setup(),
    setup_swarms(N, Opts, []).

setup_swarms() ->
    setup_swarms(2, []).

teardown_swarms(Swarms) ->
    Names =  lists:map(fun libp2p_swarm:name/1, Swarms),
    lists:map(fun libp2p_swarm:stop/1, Swarms),
    lists:foreach(fun(N) ->
                          SwarmDir = filename:join(libp2p_config:data_dir(), N),
                          rm_rf(SwarmDir)
                  end, Names).

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

with(Pairs) ->
    [fun(Swarms) ->
             {Name, fun() -> F(Swarms) end}
     end || {Name, F} <- Pairs].

withx(Tuples) ->
    [{{N, Opts},
      fun(_, Swarms) ->
              {Name, fun() -> F(Swarms) end}
      end}
     || {Name, N, Opts, F} <- Tuples].

foreach(Tuples) ->
    {foreach, fun setup_swarms/0, fun teardown_swarms/1,
     with(Tuples)}.

foreachx(Tuples) ->
    {foreachx,
     fun({N, Opts}) -> setup_swarms(N, Opts) end,
     fun (_, Swarms) -> teardown_swarms(Swarms) end,
    withx(Tuples)}.
