-module(group_twopc_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
         msg_loss_test/1
        ]).

all() ->
    [ %% this test never ends, so only run it manually
    ].

init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms(3, [{libp2p_peerbook, [{notify_time, 1000}]},
                                        {libp2p_group_gossip, [{peer_cache_timeout, 100}]},
                                        {libp2p_nat, [{enabled, false}]},
                                        {base_dir, ?config(base_dir, Config0)}]),
    [{swarms, Swarms} | Config].

end_per_testcase(_, Config) ->
    Swarms = ?config(swarms, Config),
    test_util:teardown_swarms(Swarms).

msg_loss_test(Config) ->
    Swarms =
        [LeaderS, FollowerS1, FollowerS2] =
        ?config(swarms, Config),

    ct:pal("self ~p", [self()]),

    test_util:connect_swarms(LeaderS, FollowerS1),
    test_util:connect_swarms(LeaderS, FollowerS2),

    test_util:await_gossip_groups(Swarms, 35),
    test_util:await_gossip_streams(Swarms, 35),

    Members = [libp2p_swarm:pubkey_bin(S) || S <- Swarms],

    %% G1 takes input and broadcasts
    LeaderArgs = [twopc_handler, [Members, true, undefined], [{create, true}]],
    {ok, LeaderG} = libp2p_swarm:add_group(LeaderS, "twopc", libp2p_group_relcast, LeaderArgs),

    Follower1ArgsC = [twopc_handler, [Members, 2, 1], [{create, true}]],
    Follower1Args = [twopc_handler, [Members, 2, 1]],
    {ok, Follower1G} = libp2p_swarm:add_group(FollowerS1, "twopc", libp2p_group_relcast,
                                              Follower1ArgsC),

    Follower2ArgsC = [twopc_handler, [Members, 3, 1], [{create, true}]],
    Follower2Args = [twopc_handler, [Members, 3, 1]],
    {ok, Follower2G} = libp2p_swarm:add_group(FollowerS2, "twopc", libp2p_group_relcast,
                                              Follower2ArgsC),

    timer:sleep(500), % wait a bit for groups to come up, need to
                      % figure out how to wait for this better

    Runner = self(),
    Restarter =
        spawn(
          fun() ->
                  receive go -> ok end,
                  fun Restart(Groups) ->
                          receive
                              stop ->
                                  Runner ! all_done,
                                  ok;
                              pause ->
                                  receive
                                      go ->
                                          Restart(Groups)
                                  end;
                              print ->
                                  lists:map(
                                    fun({_S, G, _A}) ->
                                            C = supervisor:which_children(G),
                                            {server, P, _, _} = hd(C),
                                            ct:pal("group ~p: ~p", [G, sys:get_state(P)])
                                    end, Groups),
                                  receive
                                      go ->
                                          Restart(Groups)
                                  end
                          after 0 ->
                                  E = {Swarm, Group, Args} = lists:nth(rand:uniform(length(Groups)), Groups),

                                  case rand:uniform(2) of
                                      0 ->
                                          ok = libp2p_group_relcast:handle_command(Group, stop);
                                      2 ->
                                          ok = libp2p_swarm:remove_group(Swarm, "twopc")
                                  end,

                                  lager:info("waiting on ~p", [Group]),
                                  Ref = erlang:monitor(process, Group),
                                  receive
                                      {'DOWN', Ref, process, Group, _} ->
                                          lager:info("test got down from ~p", [Group]),
                                          ok
                                  after 10000 ->
                                          error(group_timeout)
                                  end,
                                  timer:sleep(1000),
                                  {ok, Replacement} =
                                      libp2p_swarm:add_group(Swarm, "twopc", libp2p_group_relcast, Args),
                                  timer:sleep(50),
                                  Groups1 = lists:delete(E, Groups),
                                  Restart([{Swarm, Replacement, Args} | Groups1])
                          end
                  end([{FollowerS1, Follower1G, Follower1Args},
                       {FollowerS2, Follower2G, Follower2Args}])
          end),

    L = fun Loop(250) ->
                ok;
            Loop(N) ->
                case N of 3 -> Restarter ! go; _ -> ok end,
                Timeout = case N of 1 -> 160000; _ -> 15000 end,
                Start = erlang:monotonic_time(millisecond),
                {ok, N} = libp2p_group_relcast:handle_command(LeaderG, {set_val, self(), N}),
                receive
                    {finished, N} ->
                        End = erlang:monotonic_time(millisecond),
                        ct:pal("setting var to ~p took ~p", [N, End - Start]),
                        Loop(N + 1)
                after Timeout ->
                        Restarter ! print,
                        error(timeout)
                end
        end,
    L(1),

    Restarter ! stop,
    receive all_done -> ok
    after 5000 -> ok % error(couldnt_stop_rec)
    end,

    %% error(whoa),
    ok.

