-module(stream_test).

-include_lib("eunit/include/eunit.hrl").
-include("src/libp2p_yamux.hrl").

stream_test_() ->
    test_util:foreach(
      [ fun auto_close/1,
        fun close/1,
        fun timeout/1,
        fun window/1
      ]).

auto_close([S1, S2]) ->
    ok = serve_stream:register(S2, "serve"),
    {Stream, Server} = serve_stream:dial(S1, S2, "serve"),

    % Write some data from the server
    ?assertEqual(ok, serve_stream:send(Server, <<"hello">>)),
    % Read out 1 byte to have ensure the data arrived
    ?assertEqual({ok, <<"h">>}, libp2p_connection:recv(Stream, 1)),
    % then close the server
    ?assertEqual(ok, serve_stream:close(Server)),
    % double closing is a noop
    ?assertEqual(ok, serve_stream:close(Server)),
    % verify close_state for server
    ?assertEqual(closed, serve_stream:close_state(Server)),

    % wait for the client to see it
    ok = test_util:wait_until(fun() -> libp2p_connection:close_state(Stream) == pending end,
                              10, 1000),
    ?assertEqual(pending, libp2p_connection:close_state(Stream)),

    % can't write to a closed connection
    ?assertEqual({error, closed}, serve_stream:send(Server, <<"nope">>)),
    % and the remote side (client in this case) also can't send
    ?assertEqual({error, closed}, libp2p_connection:send(Stream, <<"nope">>)),

    % the client can't ask for more than is cached
    ?assertEqual({error, closed}, libp2p_connection:recv(Stream, 10)),
    % but the client can read remaining data
    ?assertEqual({ok, <<"el">>}, libp2p_connection:recv(Stream, 2)),
    ?assertEqual({ok, <<"lo">>}, libp2p_connection:recv(Stream, 2)),
    % and the stream closes when data is exhausted
    ?assertEqual({error, closed}, libp2p_connection:recv(Stream, 1)),
    ?assertEqual(closed, libp2p_connection:close_state(Stream)),

    ok.

close([S1 ,S2]) ->
    ok = serve_stream:register(S2, "serve"),
    {Stream, Server} = serve_stream:dial(S1, S2, "serve"),

    % Write some data from the server
    ?assertEqual(ok, serve_stream:send(Server, <<"hello">>)),
    % close the server
    ?assertEqual(ok, serve_stream:close(Server)),
    % wait for the client to see it
    ok = test_util:wait_until(fun() -> libp2p_connection:close_state(Stream) == pending end,
                              10, 1000),

    % Close the client
    ?assertEqual(ok, libp2p_connection:close(Stream)),
    ?assertEqual(closed, libp2p_connection:close_state(Stream)),

    ok.


timeout([S1, S2]) ->
    serve_stream:register(S2, "serve"),
    {Stream, Server} = serve_stream:dial(S1, S2, "serve"),

    % Test receiving: simple timeout for a small number of bytes < window
    ?assertEqual({error, timeout}, serve_stream:recv(Server, 1, 100)),

    % Test sending just a bit ore than a window.  This will timeout
    % for the extra byte that is being sent > max_window
    BigData = <<0:(8 * (?DEFAULT_MAX_WINDOW_SIZE + 1))/integer>>,
    ?assertEqual({error, timeout}, libp2p_connection:send(Stream, BigData, 100)),

    ok.

window([S1, S2]) ->
    serve_stream:register(S2, "serve"),
    {Stream, Server} = serve_stream:dial(S1, S2, "serve"),

    SmallData = <<41, 42, 43>>,
    libp2p_connection:send(Stream, SmallData),
    ?assertEqual({ok, SmallData}, serve_stream:recv(Server, byte_size(SmallData))),

    BigData = <<0:(8 * 2 * ?DEFAULT_MAX_WINDOW_SIZE)/integer>>,
    BigDataSize = byte_size(BigData),
    Server ! {recv, BigDataSize, 1000},
    libp2p_connection:send(Stream, BigData),
    Received = receive
                   {recv, BigDataSize, R} -> R
               end,
    ?assertEqual({ok, BigData}, Received),

    ok.
