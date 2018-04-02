-module(swarm_test).

-include_lib("eunit/include/eunit.hrl").

swarm_test_() ->
    test_util:foreachx(
     [
      {"Swarm accessors", 1, [], fun accessor/1}
     ]).

accessor([S1]) ->
    {ok, PubKey, _} = libp2p_swarm:keys(S1),
    ?assertEqual(libp2p_crypto:pubkey_to_address(PubKey), libp2p_swarm:address(S1)),

    ?assertEqual([], libp2p_swarm:opts(S1, [])),
    ?assertMatch("swarm" ++ _, atom_to_list(libp2p_swarm:name(S1))),

    ok.
