-module(identify_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([identify_test/1]).

all() ->
    [identify_test].

init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms([{base_dir, ?config(base_dir, Config0)},
                                     {libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}
                                    ]),
    [{swarms, Swarms}| Config].

end_per_testcase(_, Config) ->
    Swarms = ?config(swarms, Config),
    test_util:teardown_swarms(Swarms).

identify_test(Config) ->
    [S1, S2] = ?config(swarms, Config),
    S1Addrs = libp2p_swarm:listen_addrs(S1),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    % identify S2
    {ok, Session} = libp2p_swarm:connect(S1, S2Addr),
    libp2p_session:identify(Session, self(), my_data),
    {ok, Identify} = receive
                         {handle_identify, my_data, R} -> R
                     after 1000 -> error(timeout)
                     end,

    %% Compare addresses
    ?assertEqual(libp2p_swarm:pubkey_bin(S2), libp2p_identify:pubkey_bin(Identify)),

    %% Compare observed ip addresses and port.
    S1Addr = libp2p_identify:observed_addr(Identify),
    ?assert(lists:member(S1Addr, S1Addrs)),

    ok.
