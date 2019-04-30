-module(stream_SUITE).

-include("src/libp2p_yamux.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([auto_close_test/1, close_test/1, timeout_test/1, window_test/1, idle_test/1]).

all() ->
    [
     auto_close_test,
     close_test,
     timeout_test,
     window_test,
     idle_test
    ].

init_per_testcase(_, Config) ->
    Swarms = [S1, S2] =
        test_util:setup_swarms(2, [
                                   {libp2p_group_gossip,
                                    [{peerbook_connections, 0}]
                                   },
                                   {libp2p_session,
                                    [{idle_timeout, 30000}]
                                   },
                                  {libp2p_stream,
                                   [{idle_timeout, 2000}]
                                  }
                                  ]),

    ok = serve_stream:register(S2, "serve"),
    {Stream, Server, ServerConnection} = serve_stream:dial(S1, S2, "serve"),

    [{swarms, Swarms}, {serve, {Stream, Server}}, {server_connection, ServerConnection} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

%% Tests
%%

auto_close_test(Config) ->
    {Stream, Server} = proplists:get_value(serve, Config),

    % Write some data from the server
    ok = serve_stream:send(Server, <<"hello">>),
    % Read out 1 byte to have ensure the data arrived
    {ok, <<"h">>} = libp2p_connection:recv(Stream, 1),
    % then close the server
    ok = serve_stream:close(Server),
    % double closing is a noop
    ok = serve_stream:close(Server),
    % verify close_state for server
    closed = serve_stream:close_state(Server),

    % wait for the client to see it
    ok = test_util:wait_until(fun() -> libp2p_connection:close_state(Stream) == pending end,
                              10, 1000),
    pending = libp2p_connection:close_state(Stream),

    % can't write to a closed connection
    {error, closed} = serve_stream:send(Server, <<"nope">>),
    % and the remote side (client in this case) also can't send
    {error, closed} = libp2p_connection:send(Stream, <<"nope">>),

    % the client can't ask for more than is cached
    {error, closed} = libp2p_connection:recv(Stream, 10),
    % but the client can read remaining data
    {ok, <<"el">>} = libp2p_connection:recv(Stream, 2),
    {ok, <<"lo">>} = libp2p_connection:recv(Stream, 2),
    % and the stream closes when data is exhausted
    {error, closed} = libp2p_connection:recv(Stream, 1),
    closed = libp2p_connection:close_state(Stream),

    ok.

close_test(Config) ->
    {Stream, Server} = proplists:get_value(serve, Config),

    % Write some data from the server
    ok =  serve_stream:send(Server, <<"hello">>),
    % close the server
    ok = serve_stream:close(Server),
    % wait for the client to see it
    ok = test_util:wait_until(fun() -> libp2p_connection:close_state(Stream) == pending end,
                              10, 1000),

    % Close the client
    ok = libp2p_connection:close(Stream),
    closed = libp2p_connection:close_state(Stream),

    ok.


timeout_test(Config) ->
    {Stream, Server} = proplists:get_value(serve, Config),

    % Test receiving: simple timeout for a small number of bytes < window
    {error, timeout} = serve_stream:recv(Server, 1, 100),

    % Test sending just a bit ore than a window.  This will timeout
    % for the extra byte that is being sent > max_window
    BigData = <<0:(8 * (?DEFAULT_MAX_WINDOW_SIZE + 1))/integer>>,
    {error, timeout} = libp2p_connection:send(Stream, BigData, 100),

    ok.

window_test(Config) ->
    {Stream, Server} = proplists:get_value(serve, Config),

    SmallData = <<41, 42, 43>>,
    libp2p_connection:send(Stream, SmallData),
    {ok, SmallData} = serve_stream:recv(Server, byte_size(SmallData)),

    BigData = <<0:(8 * 2 * ?DEFAULT_MAX_WINDOW_SIZE)/integer>>,
    BigDataSize = byte_size(BigData),
    Server ! {recv, BigDataSize, 1000},
    libp2p_connection:send(Stream, BigData),
    Received = receive
                   {recv, BigDataSize, R} -> R
               end,
    {ok, BigData} =  Received,

    ok.

idle_test(Config) ->
    {Stream, Server} = proplists:get_value(serve, Config),
    ServerConnection = proplists:get_value(server_connection, Config),

    StreamPid = element(3, Stream),
    ServerStreamPid = element(3, ServerConnection),
    %% Confirm that both the client and server underlying streams are stopped
    ok = test_util:wait_until(fun() ->
                                      not erlang:is_process_alive(StreamPid) andalso
                                          not erlang:is_process_alive(ServerStreamPid)
                              end),

    %% serve_stream does not really behave like a proper stream so it
    %% will not stop unless told to do so explicitly. We can use this
    %% here to check that at least it acknowledges that the connection
    %% is closed
    {error, closed} = serve_stream:recv(Server, 1, 100),

    ok.
