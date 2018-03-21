-module(listen_test).

-include_lib("eunit/include/eunit.hrl").


port0_test() ->
    test_util:setup(),

    {ok, Swarm} = libp2p_swarm:start(test, []),
    ?assertEqual([], libp2p_swarm:listen_addrs(Swarm)),

    ?assertEqual(ok, libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0")),

    ?assertMatch(["/ip4/127.0.0.1/" ++ _], libp2p_swarm:listen_addrs(Swarm)),

    ?assertEqual(ok, libp2p_swarm:listen(Swarm, "/ip6/::1/tcp/0")),
    ?assertMatch(["/ip4/127.0.0.1/" ++ _, "/ip6/::1/" ++ _], libp2p_swarm:listen_addrs(Swarm)),

    test_util:teardown_swarms([Swarm]).

addr0_test() ->
    test_util:setup(),

    {ok, Swarm} = libp2p_swarm:start(test),

    ListenAddrs = libp2p_swarm:listen_addrs(Swarm),
    ?assert(length(ListenAddrs) > 0),

    PAddrs = lists:map(fun(N) -> multiaddr:protocols(multiaddr:new(N)) end, ListenAddrs),
    lists:foreach(fun([{"ip4", IP},{"tcp", Port}]) ->
                          ?assertMatch({ok, _}, inet:parse_ipv4_address(IP)),
                          ?assert(list_to_integer(Port) > 0)
                  end, PAddrs),

    test_util:teardown_swarms([Swarm]).

already_test() ->
    test_util:setup(),

    {ok, Swarm} = libp2p_swarm:start(test, [{listen_addr, "/ip4/127.0.0.1/tcp/0"}]),
    [ListenAddr] = libp2p_swarm:listen_addrs(Swarm),
    io:format("L ~p", [ListenAddr]),

    ?assertMatch({error, _}, libp2p_swarm:listen(Swarm, ListenAddr)),
    ?assertMatch({error, _}, libp2p_swarm:start(test2, [{listen_addr, ListenAddr}])),

    test_util:teardown_swarms([Swarm]).

bad_addr_test() ->
    test_util:setup(),
    ?assertMatch({error, {unsupported_address, _}},
                 libp2p_swarm:start(test, [{listen_addr, "/onion/timaq4ygg2iegci7:1234"}])),
    ?assertMatch({error, {unsupported_address, _}},
                 libp2p_swarm:start(test2, [{listen_addr, "/udp/1234/udt"}])).
