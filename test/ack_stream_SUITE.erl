-module(ack_stream_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([handle_data/3, handle_ack/2]).
-export([ack_test/1]).


all() ->
    [ack_test].

init_per_testcase(_, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    libp2p_swarm:add_stream_handler(S2, "serve_ack_frame",
                                    {libp2p_framed_stream, server,
                                     [libp2p_ack_stream, ack_server_ref, ?MODULE, self()]}),
    Stream = test_util:dial(S1, S2, "serve_ack_frame"),
    {ok, Client} = libp2p_framed_stream:client(libp2p_ack_stream, Stream,
                                               [ack_client_ref, ?MODULE, self()]),
    [{swarms, Swarms}, {client, Client} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

ack_test(Config) ->
    Client = proplists:get_value(client, Config),
    libp2p_ack_stream:send(Client, <<"hello">>),
    receive
        {handle_data, ack_server_ref, <<"hello">>} -> ok
    after 100 -> erlang:exit(timeout)
    end,

    receive
        {handle_ack, ack_client_ref} -> ok
    after 100 -> erlang:exit(timeout)
    end,
    ok.

handle_data(Pid, Ref, Bin) ->
    Pid ! {handle_data, Ref, Bin},
    ok.

handle_ack(Pid, Ref) ->
    Pid ! {handle_ack, Ref},
    ok.
