-module(identify_test).

-include_lib("eunit/include/eunit.hrl").


identify_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S1Addr|_] = libp2p_swarm:listen_addrs(S1),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    % identify S2
    {ok, Identify} = libp2p_identify:identify(S1, S2Addr),
    % check some basic properties
    ?assertEqual("identify/1.0.0", libp2p_identify:protocol_version(Identify)),
    ?assert(lists:member(multiaddr:new(S2Addr), libp2p_identify:listen_addrs(Identify))),
    ?assertMatch(("erlang-libp2p/" ++  _), libp2p_identify:agent_version(Identify)),

    % Compare observed ip addresses. We ignore ports for now since
    % they may be different until the reuseport branch lands
    % TODO: Compare ports hard once reuseport lands
    [S1IP,  _] = multiaddr:protocols(multiaddr:new(S1Addr)),
    [ObservedIP, _] = multiaddr:protocols(libp2p_identify:observed_addr(Identify)),
    ?assertEqual(S1IP, ObservedIP),

    test_util:teardown_swarms(Swarms),
    ok.
