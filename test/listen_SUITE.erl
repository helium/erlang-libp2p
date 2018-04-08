-module(listen_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([port0_test/1, addr0_test/1, already_test/1, bad_addr_test/1]).

all() ->
    [
      port0_test
    , addr0_test
    , already_test
    , bad_addr_test
    ].

init_per_testcase(_, Config) ->
    test_util:setup(),
    {ok, Swarm} = libp2p_swarm:start(test),
    [{swarm, Swarm} | Config].

end_per_testcase(_, Config) ->
    Swarm = proplists:get_value(swarm, Config),
    test_util:teardown_swarms([Swarm]).

%% Tests
%

port0_test(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    [] = libp2p_swarm:listen_addrs(Swarm),
    ok = libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0"),

    ["/ip4/127.0.0.1/" ++ _] = libp2p_swarm:listen_addrs(Swarm),

    ok = libp2p_swarm:listen(Swarm, "/ip6/::1/tcp/0"),
    ["/ip4/127.0.0.1/" ++ _, "/ip6/::1/" ++ _] = libp2p_swarm:listen_addrs(Swarm),

    ok.

addr0_test(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    ok =  libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

    ListenAddrs = libp2p_swarm:listen_addrs(Swarm),
    true = length(ListenAddrs) > 0,

    PAddrs = lists:map(fun(N) -> multiaddr:protocols(multiaddr:new(N)) end, ListenAddrs),
    lists:foreach(fun([{"ip4", IP},{"tcp", Port}]) ->
                          {ok, _} = inet:parse_ipv4_address(IP),
                          true = list_to_integer(Port) > 0
                  end, PAddrs),
    ok.

already_test(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    ok = libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0"),
    [ListenAddr] = libp2p_swarm:listen_addrs(Swarm),

    {error, _} = libp2p_swarm:listen(Swarm, ListenAddr),

    ok.

bad_addr_test(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    {error, {unsupported_address, _}} = libp2p_swarm:listen(Swarm, "/onion/timaq4ygg2iegci7:1234"),
    {error, {unsupported_address, _}} = libp2p_swarm:listen(Swarm, "/udp/1234/udt"),

    ok.
