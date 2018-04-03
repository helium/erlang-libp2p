-module(session_agent_number_test).

-include_lib("eunit/include/eunit.hrl").

get_peer(Swarm) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    Addr = libp2p_swarm:address(Swarm),
    {ok, Peer} = libp2p_peerbook:get(PeerBook, Addr),
    Peer.

connection_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(2, [{session_agent, libp2p_session_agent_number},
                                                   {libp2p_session_agent_number,
                                                    [{peerbook_connections, 1}]
                                                   }
                                                  ]),

    %% Add S2 to the S1 peerbook. This shoud cause the S1 session
    %% agent to connect to S2
    S1PeerBook = libp2p_swarm:peerbook(S1),

    %% No initial sessions since peerbook is empty
    S1Agent = libp2p_swarm:session_agent(S1),
    ?assertEqual([], libp2p_session_agent:sessions(S1Agent)),

    %% Fake a drop timer to see if sessions are attempted
    S1Agent ! drop_timeout,
    ?assertEqual([], libp2p_session_agent:sessions(S1Agent)),

    %% Now tell S1 about S2
    libp2p_peerbook:put(S1PeerBook, [get_peer(S2)]),

    %% Verify that S2 finds out about S1
    S2PeerBook = libp2p_swarm:peerbook(S2),
    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S2PeerBook, libp2p_swarm:address(S1)) end),
    ?assertEqual(1, length(libp2p_session_agent:sessions(S1Agent))),

    %% Make S1 forget about S1
    libp2p_peerbook:remove(S1PeerBook, libp2p_swarm:address(S2)),

    %% And fake a timeout to ensure that the agent forgets about S2
    S1Agent ! drop_timeout,
    ?assertEqual([], libp2p_session_agent:sessions(S1Agent)),

    test_util:teardown_swarms(Swarms).

stream_test() ->
    %% Set up S1 to be the client swarm..one peer connection, with a sample client spec
    [S1] = test_util:setup_swarms(1, [ {session_agent, libp2p_session_agent_number},
                                       {libp2p_session_agent_number,
                                        [ {peerbook_connections, 1},
                                          {stream_clients,
                                           [ {"test", {serve_framed_stream, [self()]}}
                                           ]}
                                        ]}
                                     ]),
    %% Set up S2 as the server. No peer connections but with a
    %% registered test stream handler
    [S2] = test_util:setup_swarms(1, [ {session_agent, libp2p_session_agent_number},
                                       {libp2p_session_agent_number, [{peerbook_connections, 0}]}
                                       ]),
    %% Add the serve stream handler to S2
    serve_framed_stream:register(S2, "test"),

    %% Add S2 to the S1 peerbook. This should cause the S1 session
    %% agent to connect to S2
    S1PeerBook = libp2p_swarm:peerbook(S1),
    libp2p_peerbook:put(S1PeerBook, [get_peer(S2)]),

    %% Verify that S1 should auto start the client_specs above which
    %% will cause the serve_framed_stream server to call us back when
    %% it accepts stream and the client to call us back once it
    %% connects

    Server = receive
                 {hello_server, S} -> S
             after 2000 -> error(timeout)
             end,

    Client = receive
                 {hello_client, C} -> C
             after 2000 -> error(timeout)
             end,

    %% Send some data just to be sure
    serve_framed_stream:send(Client, <<"hello">>),
    ok = test_util:wait_until(fun() -> serve_framed_stream:data(Server) == <<"hello">> end),

    test_util:teardown_swarms([S1, S2]).

seed_test() ->
    %% Set up S2 as the seed.
    [S2] = test_util:setup_swarms(1, [ {session_agent, libp2p_session_agent_number},
                                       {libp2p_session_agent_number, [{peerbook_connections, 0}]}
                                       ]),

    [S2ListenAddr | _] = libp2p_swarm:listen_addrs(S2),

    %% Set up S1 to be the client..one peer connection, and S2 as the seed node
    [S1] = test_util:setup_swarms(1, [ {session_agent, libp2p_session_agent_number},
                                       {libp2p_session_agent_number,
                                        [ {peerbook_connections, 1},
                                          {seed_nodes, [S2ListenAddr]}
                                        ]}
                                     ]),

    %% Verify that S2 finds out about S1
    S2PeerBook = libp2p_swarm:peerbook(S2),
    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S2PeerBook, libp2p_swarm:address(S1)) end),

    %% And the S1 has a session to S2
    S1Agent = libp2p_swarm:session_agent(S1),
    ?assertEqual(1, length(libp2p_session_agent:sessions(S1Agent))),

    test_util:teardown_swarms([S1, S2]).
