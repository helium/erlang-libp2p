-module(ack_stream_SUITE).


-behavior(libp2p_ack_stream).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accept_stream/3, handle_data/3, handle_ack/5]).
-export([ack_test/1]).


all() ->
    [ack_test].

setup_swarms(HandleDataResponse, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    libp2p_swarm:add_stream_handler(S2, "serve_ack_frame",
                                    {libp2p_ack_stream, server, [?MODULE, {self(), HandleDataResponse}]}),
    Connection = test_util:dial(S1, S2, "serve_ack_frame"),
    {ok, Stream} = libp2p_ack_stream:client(Connection, [client, ?MODULE, self()]),
    [{swarms, Swarms}, {client, Stream} | Config].

init_per_testcase(ack_test, Config) ->
    setup_swarms(ok, Config).

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

ack_test(Config) ->
    Client = proplists:get_value(client, Config),
    pending = libp2p_framed_stream:send(Client, {<<"hello">>, 1, false}, 100),

    receive
        {handle_data, {server, S}, <<"hello">>, Seq, false} -> libp2p_ack_stream:send_ack(S, Seq, false, false)
    after 1000 ->
              ct:pal("Messages: ~p", [erlang:process_info(self(), [messages])]),
              erlang:exit(timeout_data)
    end,

    receive
        {handle_ack, client, _Seq, false, false}-> ok
    after 1000 ->
              ct:pal("Messages: ~p", [erlang:process_info(self(), [messages])]),
              erlang:exit(timeout_done)
    end,

    ok.

accept_stream({Pid, _}, StreamPid, Path) ->
    Pid ! {accept_stream, StreamPid, Path},
    {ok, {server, self()}}.

handle_data({Pid, Response}, Ref, {Bin, Seq, Last}) ->
    Pid ! {handle_data, Ref, Bin, Seq, Last},
    Response.

handle_ack(Pid, Ref, Seq, Reset, Range) ->
    Pid ! {handle_ack, Ref, Seq, Reset, Range},
    ok.
