-module(swarm_test).

-include_lib("eunit/include/eunit.hrl").

accessor_test() ->
    Swarms = [S1] = test_util:setup_swarms(1),

    {_, PubKey} = libp2p_swarm:keys(S1),
    ?assertEqual(libp2p_crypto:pubkey_to_address(PubKey), libp2p_swarm:address(S1)),

    test_util:teardown_swarms(Swarms).
