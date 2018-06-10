-module(identify_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([identify_test/1]).

all() ->
    [identify_test].

init_per_testcase(_, Config) ->
    Swarms = test_util:setup_swarms(),
    [{swarms, Swarms}| Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

identify_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),
    [S1Addr|_] = libp2p_swarm:listen_addrs(S1),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    % identify S2
    {ok, Session} = libp2p_swarm:connect(S1, S2Addr),
    libp2p_identify:spawn_identify(Session, self(), ident),
    Identify = receive
                   {identify, ident, Session, Ident} -> Ident
               after 1000 -> error(timeout)
               end,
    % check some basic properties
    "identify/1.0.0" = libp2p_identify:protocol_version(Identify),

    true = lists:member(multiaddr:new(S2Addr), libp2p_identify:listen_addrs(Identify)),
    "erlang-libp2p/" ++  _ = libp2p_identify:agent_version(Identify),

    % Compare observed ip addresses and port.
    S1Addr = libp2p_identify:observed_addr(Identify),
    [S1IP,  S1Port] = multiaddr:protocols(multiaddr:new(S1Addr)),
    [S1IP, S1Port] = multiaddr:protocols(libp2p_identify:observed_maddr(Identify)),

    %% Compare stream protocols
    StreamHandlers = lists:sort([Key || {Key, _} <- libp2p_swarm:stream_handlers(S1)]),
    StreamHandlers = lists:sort(libp2p_identify:protocols(Identify)),

    ok.
