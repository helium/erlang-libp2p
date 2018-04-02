-module(listen_test).

-include_lib("eunit/include/eunit.hrl").

listen_test_() ->
    {foreach,
     fun() ->
             test_util:setup(),
             {ok, Swarm} = libp2p_swarm:start(test),
             Swarm
     end,
     fun(Swarm) ->
             test_util:teardown_swarms([Swarm])
     end,
     test_util:with(
      [ {"Port 0", fun port0/1},
        {"Address 0", fun addr0/1},
        {"Already listening", fun already/1},
        {"Bad address", fun bad_addr/1}
      ])}.

port0(Swarm) ->
    ?assertEqual([], libp2p_swarm:listen_addrs(Swarm)),

    ?assertEqual(ok, libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0")),

    ?assertMatch(["/ip4/127.0.0.1/" ++ _], libp2p_swarm:listen_addrs(Swarm)),

    ?assertEqual(ok, libp2p_swarm:listen(Swarm, "/ip6/::1/tcp/0")),
    ?assertMatch(["/ip4/127.0.0.1/" ++ _, "/ip6/::1/" ++ _], libp2p_swarm:listen_addrs(Swarm)),

    ok.

addr0(Swarm) ->
    ?assertEqual(ok, libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0")),

    ListenAddrs = libp2p_swarm:listen_addrs(Swarm),
    ?assert(length(ListenAddrs) > 0),

    PAddrs = lists:map(fun(N) -> multiaddr:protocols(multiaddr:new(N)) end, ListenAddrs),
    lists:foreach(fun([{"ip4", IP},{"tcp", Port}]) ->
                          ?assertMatch({ok, _}, inet:parse_ipv4_address(IP)),
                          ?assert(list_to_integer(Port) > 0)
                  end, PAddrs),
    ok.

already(Swarm) ->
    ok = libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0"),
    [ListenAddr] = libp2p_swarm:listen_addrs(Swarm),

    ?assertMatch({error, _}, libp2p_swarm:listen(Swarm, ListenAddr)),

    ok.

bad_addr(Swarm) ->
    ?assertMatch({error, {unsupported_address, _}},
                 libp2p_swarm:listen(Swarm, "/onion/timaq4ygg2iegci7:1234")),
    ?assertMatch({error, {unsupported_address, _}},
                 libp2p_swarm:listen(Swarm, "/udp/1234/udt")),

    ok.
