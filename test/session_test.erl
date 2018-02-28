-module(session_test).

-include_lib("eunit/include/eunit.hrl").

open_close_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),
    {ok, Session1} = libp2p_swarm:connect(S1, S2Addr),
    ?assertEqual(open, libp2p_session:close_state(Session1)),

    % open a reverse session
    {Session1Addr, _} = libp2p_session:addr_info(Session1),
    {ok, Session2} = libp2p_swarm:connect(S2, Session1Addr),

    % open another forward session, ensure session reuse
    {ok, Session3} = libp2p_swarm:connect(S1, S2Addr, [], 100),
    ?assertEqual(Session1, Session3),

    % and another one, but make it unique
    {ok, Session4} = libp2p_swarm:connect(S1, S2Addr, [{unique_session, true}], 100),
    ?assertNotEqual(Session1, Session4),
    libp2p_session:close(Session4),

    {ok, Stream1} = libp2p_session:open(Session1),
    ?assertEqual(libp2p_connection:addr_info(Stream1), libp2p_session:addr_info(Session1)),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session1)) == 1 end),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session2)) == 1 end),

    % Can write (up to a window size of) data without anyone on the
    % other side
    ?assertEqual(ok, libp2p_multistream_client:handshake(Stream1)),

    % Close stream after sending some data on it
    ?assertEqual(ok, libp2p_connection:close(Stream1)),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session1)) == 0 end),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session2)) == 0 end),
    ?assertEqual({error, closed}, libp2p_connection:send(Stream1, <<"hello">>)),

    libp2p_session:close(Session1),
    test_util:teardown_swarms(Swarms),
    ok.

ping_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    {ok, Session} = libp2p_swarm:connect(S1, S2Addr),
    ?assertMatch({ok, _}, libp2p_session:ping(Session)),

    test_util:teardown_swarms(Swarms),
    ok.
