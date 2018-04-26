-module(group_relcast_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([unicast_test/1, restart_test/1]).

all() ->
    [ %% restart_test,
      unicast_test
    ].

init_per_testcase(_, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(2, []),
    Addrs = [libp2p_swarm:address(S1),
             libp2p_swarm:address(S2)],
    [{swarms, Swarms}, {swarm_addrs, Addrs} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

unicast_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),
    Members = proplists:get_value(swarm_addrs, Config),

    test_util:connect_swarms(S1, S2),

    %% Wait to see if S1 knows about S2
    ok = test_util:wait_until(fun() ->
                                      libp2p_peerbook:is_key(libp2p_swarm:peerbook(S1),
                                                             libp2p_swarm:address(S2))
                              end),
    %% And if S2 knows about S1
    ok = test_util:wait_until(fun() ->
                                      libp2p_peerbook:is_key(libp2p_swarm:peerbook(S2),
                                                             libp2p_swarm:address(S1))
                              end),

    G1Args = ["test", lists:delete(libp2p_swarm:address(S1), Members), input_unicast(1), undefined],
    {ok, G1} = libp2p_group_relcast:start_link(S1, relcast_handler, G1Args),

    G2Args = ["test", lists:delete(libp2p_swarm:address(S2), Members), undefined, handle_msg(ok)],
    {ok, _G2} = libp2p_group_relcast:start_link(S2, relcast_handler, G2Args),

    libp2p_group_relcast:handle_input(G1, <<"hello">>),

    receive
        {handle_msg, 1, <<"hello">>} -> ok
    after 1000 -> error(timeout)
    end,
    ok.

restart_test(_Config) ->
    %% Restarting a relcast group should resend outbound messages that
    %% were not acknowledged, and re-deliver inbould messages to the
    %% handler.
    ok.


%% Utils
%%

input_unicast(Index) ->
    fun(Msg) ->
            io:format("INPUT"),
            {send, [{unicast, Index, Msg}]}
    end.

handle_msg(Resp) ->
    Parent = self(),
    fun(Index, Msg) ->
            io:format("HANDLE"),
            Parent ! {handle_msg, Index, Msg},
            Resp
    end.
