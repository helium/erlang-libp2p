-module(session_agent).

-export([agent_number_test/0]).

get_peer(Swarm) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    Addr = libp2p_swarm:address(Swarm),
    {ok, Peer} = libp2p_peerbook:get(PeerBook, Addr),
    Peer.

agent_number_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(2, [{session_agent, libp2p_session_agent_number}]),

    %% Add S2 to the S1 peerbook. This shoud cause the S1 session
    %% agent to connect to S2
    S1PeerBook = libp2p_swarm:peerbook(S1),
    libp2p_peerbook:put(S1PeerBook, [get_peer(S2)]),

    S2PeerBook = libp2p_swarm:peerbook(S2),
    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S2PeerBook, libp2p_swarm:address(S1)) end),

    test_util:teardown_swarms(Swarms).
