-module(multistream_test).

-include_lib("eunit/include/eunit.hrl").


tcp_connect(Addr) ->
    [{"ip4", IPStr}, {"tcp", PortStr}] = multiaddr:protocols(multiaddr:new(Addr)),
    {ok, IP} = inet:parse_address(IPStr),
    Port  =  list_to_integer(PortStr),
    {ok, Socket} = ranch_tcp:connect(IP, Port, [inet]),
    libp2p_transport_tcp:new_connection(Socket).


multistream_test_() ->
    test_util:foreachx(
      [ {"Multistream client negotiation", 1, [], fun client_negotiate_handler/1},
        {"Multistream client list", 1, [], fun client_ls/1}
      ]).


client_ls([S1]) ->
    [Addr|_] = libp2p_swarm:listen_addrs(S1),

    Connection = tcp_connect(Addr),

    ?assertEqual(ok, libp2p_multistream_client:handshake(Connection)),
    ?assertMatch(["yamux/1.0.0" | _], libp2p_multistream_client:ls(Connection)),
    ?assertEqual(ok, libp2p_multistream_client:select("yamux/1.0.0", Connection)),

    ok.


client_negotiate_handler([S1]) ->
    [Addr|_] = libp2p_swarm:listen_addrs(S1),

    Connection = tcp_connect(Addr),

    Handlers = [{"othermux", "othermux"}, {"yamux/1.0.0", "yamux"}],
    ?assertEqual({ok, "yamux"}, libp2p_multistream_client:negotiate_handler(Handlers, "", Connection)),

    ok.
