-module(sesion_test).

-include_lib("eunit/include/eunit.hrl").
-include("src/libp2p_yamux.hrl").

stream_open_close_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Session1} = libp2p_swarm:connect(S1, S2Addr),
    {Session1Addr, _} = libp2p_session:addr_info(Session1),
    {ok, Session2} = libp2p_swarm:connect(S2, Session1Addr),

    {ok, Stream1} = libp2p_session:open(Session1),
    ?assertEqual(libp2p_connection:addr_info(Stream1), libp2p_session:addr_info(Session1)),
    ?assertEqual(1, length(libp2p_session:streams(Session1))),

    timer:sleep(1), % Allow session2 to notice the closure
    ?assertEqual(1, length(libp2p_session:streams(Session2))),
    % Can write (up to a window size of) data without anyone on the
    % other side
    ?assertEqual(ok, libp2p_multistream_client:handshake(Stream1)),


    % Close stream
    ?assertEqual(ok, libp2p_connection:close(Stream1)),
    ?assertEqual(0, length(libp2p_session:streams(Session1))),
    timer:sleep(1), % Allow session2 to notice the closure
    ?assertEqual(0, length(libp2p_session:streams(Session2))),
    ?assertEqual({error, closed}, libp2p_connection:send(Stream1, <<"hello">>)),

    test_util:teardown_swarms(Swarms),
    ok.

ping_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),
    [S2Addr] = libp2p_swarm:listen_addrs(S2),

    {ok, Session} = libp2p_swarm:connect(S1, S2Addr),
    ?assertMatch({ok, _}, libp2p_session:ping(Session)),

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

stream_window_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),

    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "echo"),

    SmallData = <<41, 42, 43>>,
    libp2p_framed_stream:send(Stream, SmallData),
    ?assertEqual({ok, SmallData}, libp2p_framed_stream:recv(Stream)),

    BigData = <<0:(8 * 2 * ?DEFAULT_MAX_WINDOW_SIZE)/integer>>,
    libp2p_framed_stream:send(Stream, BigData),
    ?assertEqual({ok, BigData}, libp2p_framed_stream:recv(Stream)),

    test_util:teardown_swarms(Swarms),
    ok.

stream_shutdown_write_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),

    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "echo"),

    libp2p_framed_stream:send(Stream, <<"hello world">>),

    libp2p_connection:shutdown(Stream, write),
    ?assertEqual({error, closed}, libp2p_framed_stream:send(Stream, <<"no write 1">>)),

    % Doing it again makes no difference
    libp2p_connection:shutdown(Stream, write),
    ?assertEqual({error, closed}, libp2p_framed_stream:send(Stream, <<"no write 1">>)),

    % We can still read 
    ?assertEqual({ok, <<"hello world">>}, libp2p_framed_stream:recv(Stream)),

    libp2p_connection:shutdown(Stream, read_write),
    ?assertEqual({error, closed}, libp2p_framed_stream:recv(Stream)),
    ?assertEqual({error, closed}, libp2p_framed_stream:send(Stream, <<"no write 2">>)),

    test_util:teardown_swarms(Swarms),
    ok.


stream_shutdown_read_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),

    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "echo"),

    libp2p_connection:shutdown(Stream, read),
    ?assertEqual({error, closed}, libp2p_framed_stream:recv(Stream)),

    % We can still write
    ?assertEqual(ok, libp2p_framed_stream:send(Stream, <<"hello world">>)),

    libp2p_connection:shutdown(Stream, read_write),
    ?assertEqual({error, closed}, libp2p_framed_stream:recv(Stream)),
    ?assertEqual({error, closed}, libp2p_framed_stream:send(Stream, <<"no write 2">>)),

    test_util:teardown_swarms(Swarms),
    ok.

stream_shutdown_read_write_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),

    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "echo"),

    libp2p_connection:shutdown(Stream, read_write),
    ?assertEqual({error, closed}, libp2p_framed_stream:recv(Stream)),
    ?assertEqual({error, closed}, libp2p_framed_stream:send(Stream, <<"no write 1">>)),

    test_util:teardown_swarms(Swarms),
    ok.


stream_timeout_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "echo", {echo_stream, enter_loop, [self()]}),

    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "echo"),

    ?assertEqual({error, timeout}, libp2p_framed_stream:recv(Stream, 100)),

    test_util:teardown_swarms(Swarms),
    ok.
    




