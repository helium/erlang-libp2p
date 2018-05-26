-module(ack_stream_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accept_stream/4, handle_data/3]).
-export([ack_test/1]).


all() ->
    [ack_test].

init_per_testcase(_, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    libp2p_swarm:add_stream_handler(S2, "serve_ack_frame",
                                    {libp2p_ack_stream, server, [?MODULE, self()]}),
    Connection = test_util:dial(S1, S2, "serve_ack_frame"),
    {ok, Stream} = libp2p_ack_stream:client(Connection, [ack_client_ref, ?MODULE, self()]),
    [{swarms, Swarms}, {client, Stream} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

ack_test(Config) ->
    Client = proplists:get_value(client, Config),
    libp2p_framed_stream:send(Client, <<"hello">>, 100),
    receive
        {handle_data, ack_server_ref, <<"hello">>} -> ok
    after 100 -> erlang:exit(timeout)
    end,

    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

    %% ok.

accept_stream(Pid, _MAddr, StreamPid, Path) ->
    Pid ! {accept_stream, StreamPid, Path},
    {ok, ack_server_ref}.


handle_data(Pid, Ref, Bin) ->
    Pid ! {handle_data, Ref, Bin},
    ok.
