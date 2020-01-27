-module(test_util).

-export([setup/0, setup_swarms/0, setup_swarms/2, teardown_swarms/1,
         connect_swarms/2, disconnect_swarms/2, await_gossip_groups/1,
         wait_until/1, wait_until/3, rm_rf/1, dial/3, dial_framed_stream/5, nonl/1]).

setup() ->
    application:ensure_all_started(ranch),
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    application:ensure_all_started(throttle),
    ok.

setup_swarms(0, _Opts, Acc) ->
    Acc;
setup_swarms(N, Opts, Acc) ->
    setup_swarms(N - 1, Opts,
                 [begin
                      Name = list_to_atom("swarm" ++ integer_to_list(erlang:unique_integer([monotonic]))),
                      TmpDir = test_util:nonl(os:cmd("mktemp -d ./_build/test/tmp/XXXXXXXX")),
                      BaseDir = libp2p_config:get_opt(Opts, base_dir, TmpDir),
                      NewOpts = lists:keystore(base_dir, 1, Opts, {base_dir, BaseDir})
                        ++ [{libp2p_nat, [{enabled, false}]}],
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

disconnect_swarms(Source, Target) ->
    [TargetAddr | _] = libp2p_swarm:listen_addrs(Target),
    case libp2p_config:lookup_session(libp2p_swarm:tid(Source), TargetAddr) of
        false -> ok;
        {ok, Session} ->
            libp2p_session:close(Session),
            ok
    end.

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

dial_framed_stream(FromSwarm, ToSwarm, Name, Module, Args) ->
    [ToAddr | _] = libp2p_swarm:listen_addrs(ToSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(FromSwarm, ToAddr, Name, Module, Args),
    Stream.


await_gossip_group(Swarm, Swarms) ->
    ExpectedAddrs = sets:from_list(lists:delete(
                                     libp2p_swarm:p2p_address(Swarm),
                                     [libp2p_swarm:p2p_address(S) || S <- Swarms])),
    GossipGroup = libp2p_swarm:gossip_group(Swarm),
    test_util:wait_until(
      fun() ->
              GroupAddrs = sets:from_list(libp2p_group_gossip:connected_addrs(GossipGroup, all)),
              sets:is_subset(ExpectedAddrs, GroupAddrs)
      end).

await_gossip_groups(Swarms) ->
    lists:foreach(fun(S) ->
                          ok = await_gossip_group(S, Swarms)
                  end, Swarms).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].
