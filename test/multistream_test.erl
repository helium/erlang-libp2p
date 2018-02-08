-module(multistream_test).

-include_lib("eunit/include/eunit.hrl").

client_ls_test() ->
    Swarms = [S1] = test_util:setup_swarms(1),
    [Addr|_] = libp2p_swarm:listen_addrs(S1),

    {ok, Connection} = libp2p_transport_tcp:dial(Addr, [], 100),

    ?assertEqual(ok, libp2p_multistream_client:handshake(Connection)),
    ?assertMatch(["yamux/1.0.0" | _], libp2p_multistream_client:ls(Connection)),
    ?assertEqual(ok, libp2p_multistream_client:select("yamux/1.0.0", Connection)),

    test_util:teardown_swarms(Swarms).

client_negotiate_handler_test() ->
    Swarms = [S1] = test_util:setup_swarms(1),
    [Addr|_] = libp2p_swarm:listen_addrs(S1),

    {ok, Connection} = libp2p_transport_tcp:dial(Addr, [], 100),

    Handlers = [{"othermux", "othermux"}, {"yamux/1.0.0", "yamux"}],
    ?assertEqual({ok, "yamux"}, libp2p_multistream_client:negotiate_handler(Handlers, "", Connection)),

    test_util:teardown_swarms(Swarms).
