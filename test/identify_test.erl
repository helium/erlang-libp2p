-module(identify_test).

-include_lib("eunit/include/eunit.hrl").


identify_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "identify/1.0.0"),
    {S1Addr, _} = libp2p_connection:addr_info(Stream),
    {ok, IdentifyBin} = libp2p_framed_stream:recv(Stream),
    Identify = libp2p_identify:decode(IdentifyBin),
    ?assertEqual("identify/1.0.0", libp2p_identify:protocol_version(Identify)),
    ?assert(lists:member(multiaddr:new(S2Addr), libp2p_identify:listen_addrs(Identify))),
    ?assertEqual(multiaddr:new(S1Addr), libp2p_identify:observed_addr(Identify)),
    ?assertMatch(("erlang-libp2p/" ++  _), libp2p_identify:agent_version(Identify)),

    test_util:teardown_swarms(Swarms),
    ok.
