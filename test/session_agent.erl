-module(session_agent).

-include_lib("eunit/include/eunit.hrl").

get_peer(Swarm) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    Addr = libp2p_swarm:address(Swarm),
    {ok, Peer} = libp2p_peerbook:get(PeerBook, Addr),
    Peer.

agent_number_test() ->
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

    %% Now tell S1 about S1
    libp2p_peerbook:put(S1PeerBook, [get_peer(S2)]),

    %% Verify that S2 finds out about S1
    S2PeerBook = libp2p_swarm:peerbook(S2),
    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S2PeerBook, libp2p_swarm:address(S1)) end),

    %% Make S1 forget about S1
    libp2p_peerbook:remove(S1PeerBook, libp2p_swarm:address(S2)),

    %% And fake a timeout to ensure that the agent forgets about S2
    S1Agent ! drop_timeout,
    ?assertEqual([], libp2p_session_agent:sessions(S1Agent)),

    test_util:teardown_swarms(Swarms).
