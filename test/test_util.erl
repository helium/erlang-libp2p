-module(test_util).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

-export([setup/0, setup_swarms/1, setup_swarms/2, teardown_swarms/1,
         connect_swarms/2, disconnect_swarms/2,
         await_gossip_groups/1, await_gossip_groups/2,
         await_gossip_streams/1, await_gossip_streams/2,
         wait_until/1, wait_until/3, rm_rf/1, dial/3, dial_framed_stream/5, nonl/1,
         init_base_dir_config/3,
         tmp_dir/0, tmp_dir/1,
         cleanup_tmp_dir/1]).

setup() ->
    application:ensure_all_started(ranch),
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, info),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, info),
    application:ensure_all_started(throttle),
    ok.

setup_swarms(0, _Opts, Acc) ->
    Acc;
setup_swarms(N, Opts, Acc) ->
    setup_swarms(N - 1, Opts,
                 [begin
                      Name = list_to_atom("swarm" ++ integer_to_list(erlang:unique_integer([monotonic]))),
                      NewOpts = [{libp2p_nat, [{enabled, false}]} | Opts],
                      {ok, Pid} = libp2p_swarm:start(Name, NewOpts),
                      ok = libp2p_swarm:listen(Pid, "/ip4/0.0.0.0/tcp/0"),
                      Pid
                  end | Acc]).

setup_swarms(N, Opts) when N >= 1 ->
    setup(),
    setup_swarms(N, Opts, []).

setup_swarms(Opts) ->
    setup_swarms(2, Opts).

teardown_swarms(Swarms) ->
    lists:map(fun(S) -> catch libp2p_swarm:stop(S) end, Swarms).

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


await_gossip_group(Swarm, Swarms, Timeout0) ->
    Timeout = Timeout0 * 10,
    ExpectedAddrs = sets:from_list(lists:delete(
                                     libp2p_swarm:p2p_address(Swarm),
                                     [libp2p_swarm:p2p_address(S) || S <- Swarms])),
    GossipGroup = libp2p_swarm:gossip_group(Swarm),
    test_util:wait_until(
      fun() ->
              GroupAddrs = sets:from_list(libp2p_group_gossip:connected_addrs(GossipGroup, all)),
              sets:is_subset(ExpectedAddrs, GroupAddrs)
      end, Timeout, 100).

await_gossip_groups(Swarms) ->
    await_gossip_groups(Swarms, 45).

await_gossip_groups(Swarms, Timeout) ->
    lists:foreach(fun(S) ->
                          ok = await_gossip_group(S, Swarms, Timeout)
                  end, Swarms).

await_gossip_streams(Swarms) ->
    await_gossip_streams(Swarms, 45).

await_gossip_streams(Swarms, Timeout) when is_list(Swarms) ->
    lists:foreach(fun(S) ->
                          ok = await_gossip_stream(S, Timeout)
                  end, Swarms);
await_gossip_streams(Swarm, Timeout) ->
    await_gossip_streams([Swarm], Timeout).

await_gossip_stream(Swarm, Timeout0) ->
    Timeout = Timeout0 * 5,
    GossipGroup = libp2p_swarm:gossip_group(Swarm),
    GroupPids = libp2p_group_gossip:connected_pids(GossipGroup, all),
    test_util:wait_until(
      fun() ->
              try
                lists:all(fun(Pid)-> connected == erlang:element(1, sys:get_state(Pid)) end, GroupPids)
              catch _:_ ->
                 false
              end
      end, Timeout, 200).



nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory based off priv_data to be used as a scratch by common tests
%% and add to Config
%% @end
%%-------------------------------------------------------------------
-spec init_base_dir_config(atom(), atom(), list()) -> list().
init_base_dir_config(Mod, TestCase, Config)->
    PrivDir = ?config(priv_dir, Config),
    BaseDir = PrivDir ++ "data/" ++ erlang:atom_to_list(Mod) ++ "_" ++
                    erlang:atom_to_list(TestCase),
    [{base_dir, BaseDir} | Config].

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).
tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

%%--------------------------------------------------------------------
%% @doc
%% Deletes the specified directory
%% @end
%%-------------------------------------------------------------------
-spec cleanup_tmp_dir(list()) -> ok.
cleanup_tmp_dir(Dir)->
    os:cmd("rm -rf " ++ Dir),
    ok.
%%--------------------------------------------------------------------
%% @doc
%% create a tmp directory at the specified path
%% @end
%%-------------------------------------------------------------------
-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path)->
    ?MODULE:nonl(os:cmd("mktemp -d " ++  Path)).
