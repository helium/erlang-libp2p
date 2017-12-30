-module(sesion_test).

-include_lib("eunit/include/eunit.hrl").

stream_open_close_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Session1} = libp2p_swarm:connect(S1, S2Addr),
    {Session1Addr, _} = libp2p_session:addr_info(Session1),
    {ok, Session2} = libp2p_swarm:connect(S2, Session1Addr),

    {ok, Stream1} = libp2p_session:open(Session1),
    ?assertEqual(libp2p_connection:addr_info(Stream1), libp2p_session:addr_info(Session1)),
    ?assertEqual(1, length(libp2p_session:streams(Session1))),
    ?assertEqual(1, length(libp2p_session:streams(Session2))),
    % Can write (up to a window size of) data without anyone on the
    % other side
    ?assertEqual(ok, libp2p_multistream_client:handshake(Stream1)),

    % Half close stream, remote stream stays active
    libp2p_connection:close(Stream1),
    ?assertEqual(1, length(libp2p_session:streams(Session1))),
    ?assertEqual(1, length(libp2p_session:streams(Session2))),
    ?assertEqual({error, closed}, libp2p_connection:send(Stream1, <<"hello">>)),

    % Close completely, remote stream stays active
    ?assertEqual(ok, libp2p_connection:close(Stream1)),
    ?assertEqual(0, length(libp2p_session:streams(Session1))),
    ?assertEqual(1, length(libp2p_session:streams(Session2))),

    test_util:teardown_swarms(Swarms),
    ok.

dial_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),
    [S2Addr] = libp2p_swarm:listen_addrs(S2),

    % Dial and see if the initial path got handled
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "echo/hello"),
    ?assertEqual({ok, <<"/hello">>}, libp2p_framed_stream:recv(Stream)),

    % Echo send/response
    libp2p_framed_stream:send(Stream, <<"test">>),
    ?assertEqual({ok, <<"test">>}, libp2p_framed_stream:recv(Stream)),

    test_util:teardown_swarms(Swarms),
    ok.



