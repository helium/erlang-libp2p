-module(session_test).

-include_lib("eunit/include/eunit.hrl").
-include("src/libp2p_yamux.hrl").

-export([serve_stream/4]).

stream_open_close_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Session1} = libp2p_swarm:connect(S1, S2Addr),
    {Session1Addr, _} = libp2p_session:addr_info(Session1),
    {ok, Session2} = libp2p_swarm:connect(S2, Session1Addr),

    {ok, Stream1} = libp2p_session:open(Session1),
    ?assertEqual(libp2p_connection:addr_info(Stream1), libp2p_session:addr_info(Session1)),
    ?assertEqual(1, length(libp2p_session:streams(Session1))),

    ok = wait_until(fun() -> length(libp2p_session:streams(Session2)) == 1 end, 10, 1000),
    % Can write (up to a window size of) data without anyone on the
    % other side
    ?assertEqual(ok, libp2p_multistream_client:handshake(Stream1)),


    % Close stream
    ?assertEqual(ok, libp2p_connection:close(Stream1)),
    ok = wait_until(fun() -> length(libp2p_session:streams(Session1)) == 0 end, 10, 1000),
    ok = wait_until(fun() -> length(libp2p_session:streams(Session2)) == 0 end, 10, 1000),
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

stream_window_timeout_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    ok = libp2p_swarm:add_stream_handler(S2, "serve", {?MODULE, serve_stream, [self()]}),

    [S2Addr] = libp2p_swarm:listen_addrs(S2),
    {ok, Stream} = libp2p_swarm:dial(S1, S2Addr, "serve"),

    receive 
        {hello, Server} -> Server
    end,

    Server ! {recv, 1},
    receive
        {recv, 1, Result} -> Result
    end,
    ?assertEqual({error, timeout}, Result),

    BigData = <<0:(8 * (?DEFAULT_MAX_WINDOW_SIZE + 1))/integer>>,
    ?assertEqual({error, timeout}, libp2p_connection:send(Stream, BigData, 100)),

    test_util:teardown_swarms(Swarms),
    ok.


serve_stream(Connection, _Path, _TID, [Parent]) ->
    Parent ! {hello, self()},
    serve_loop(Connection, Parent).

serve_loop(Connection, Parent) ->
    receive
        {recv, N} ->
            Result = libp2p_connection:recv(Connection, N, 100),
            Parent ! {recv, N, Result},
            serve_loop(Connection, Parent);
         stop ->
            libp2p_connecton:close(Connection),
            ok
    end.

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
    

%%
%% Helpers
%%

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.




