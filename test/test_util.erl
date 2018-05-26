-module(test_util).

-export([setup/0, setup_swarms/0, setup_swarms/2, teardown_swarms/1,
         connect_swarms/2,
         wait_until/1, wait_until/3, rm_rf/1, dial/3]).

setup() ->
    application:ensure_all_started(ranch),
    %% application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    ok.

setup_swarms(0, _Opts, Acc) ->
    Acc;
setup_swarms(N, Opts, Acc) ->
    setup_swarms(N - 1, Opts,
                 [begin
                      Name = list_to_atom("swarm" ++ integer_to_list(erlang:unique_integer([monotonic]))),
                      TmpDir = lib:nonl(os:cmd("mktemp -d")),
                      BaseDir = libp2p_config:get_opt(Opts, base_dir, TmpDir),
                      NewOpts = lists:keystore(base_dir, 1, Opts, {base_dir, BaseDir}),
                      {ok, Pid} = libp2p_swarm:start(Name, NewOpts),
                      ok = libp2p_swarm:listen(Pid, "/ip4/0.0.0.0/tcp/0"),
                      Pid
                  end | Acc]).

setup_swarms(N, Opts) when N >= 1 ->
    setup(),
    setup_swarms(N, Opts, []).

setup_swarms() ->
    setup_swarms(2, []).

teardown_swarms(Swarms) ->
    lists:map(fun libp2p_swarm:stop/1, Swarms).

connect_swarms(Source, Target) ->
    [TargetAddr | _] = libp2p_swarm:listen_addrs(Target),
    {ok, Session} = libp2p_swarm:connect(Source, TargetAddr),
    Session.

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

dial(FromSwarm, ToSwarm, Name) ->
    [ToAddr | _] = libp2p_swarm:listen_addrs(ToSwarm),
    {ok, Connection} = libp2p_swarm:dial(FromSwarm, ToAddr, Name),
    Connection.
