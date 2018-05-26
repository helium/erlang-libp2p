-module(swarm_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accessor_test/1]).

all() ->
    [
     accessor_test
    ].

init_per_testcase(_, Config) ->
    Swarms = test_util:setup_swarms(1, []),
    [{swarms, Swarms} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

%% Tests
%%

accessor_test(Config) ->
    [S1] = proplists:get_value(swarms, Config),

    {ok, PubKey, _} = libp2p_swarm:keys(S1),
    true = libp2p_crypto:pubkey_to_address(PubKey) == libp2p_swarm:address(S1),

    [{base_dir, _}] = libp2p_swarm:opts(S1),
    "swarm" ++ _ = atom_to_list(libp2p_swarm:name(S1)),

    ok.
