-module(ack_stream_SUITE).


-behavior(libp2p_ack_stream).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accept_stream/3, handle_data/3, handle_ack/3]).
-export([ack_test/1, defer_test/1]).


all() ->
    [ack_test,
    defer_test].

setup_swarms(HandleDataResponse, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    libp2p_swarm:add_stream_handler(S2, "serve_ack_frame",
                                    {libp2p_ack_stream, server, [?MODULE, {self(), HandleDataResponse}]}),
    Connection = test_util:dial(S1, S2, "serve_ack_frame"),
    {ok, Stream} = libp2p_ack_stream:client(Connection, [client, ?MODULE, self()]),
    [{swarms, Swarms}, {client, Stream} | Config].

init_per_testcase(ack_test, Config) ->
    setup_swarms(ok, Config);
init_per_testcase(defer_test, Config) ->
    setup_swarms(defer, Config).

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

ack_test(Config) ->
    Client = proplists:get_value(client, Config),
    ok = libp2p_framed_stream:send(Client, <<"hello">>, 100),

    receive
        {handle_data, {server, _}, <<"hello">>} -> ok
    after 1000 -> erlang:exit(timeout_data)
    end,

    ok.

defer_test(Config) ->
    Client = proplists:get_value(client, Config),
    defer = libp2p_framed_stream:send(Client, <<"hello">>, 100),

    Server = receive
                 {handle_data, {server, S}, <<"hello">>} -> S
             after 1000 -> erlang:exit(timeout_data)
             end,

    libp2p_ack_stream:send_ack(Server),

    receive
        {handle_ack, client, ok} -> ok
    after 1000 -> erlang:exit(timeout_ack)
    end,

    ok.

accept_stream({Pid, _}, StreamPid, Path) ->
    Pid ! {accept_stream, StreamPid, Path},
    {ok, {server, self()}}.

handle_data({Pid, Response}, Ref, Bin) ->
    Pid ! {handle_data, Ref, Bin},
    Response.

handle_ack(Pid, Ref, Ack) ->
    Pid ! {handle_ack, Ref, Ack},
    ok.
