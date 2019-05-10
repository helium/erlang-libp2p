-module(stream_multistream_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     ls_test,
     negotiate_server_test,
     negotiate_client_test,
     negotiate_timeout_test,
     handshake_client_reverse_test,
     handshake_server_mismatch_test,
     handshake_client_mismatch_test,
     handshake_client_reverse_fail_test,
     negotiate_client_fail_test,
     negotiate_client_mismatch_test
    ].

init_per_testcase(negotiate_client_test, Config) ->
    init_client_test_common(Config, #{});
init_per_testcase(handshake_client_reverse_test, Config) ->
    init_client_test_common(Config, #{handshake_timeout => 300});
init_per_testcase(handshake_client_mismatch_test, Config) ->
    init_client_test_common(Config, #{});
init_per_testcase(negotiate_client_fail_test, Config) ->
    init_client_test_common(Config, #{});
init_per_testcase(negotiate_client_mismatch_test, Config) ->
    init_client_test_common(Config, #{});
init_per_testcase(handshake_client_reverse_fail_test, Config) ->
    init_client_test_common(Config, #{handshake_timeout => 300});
init_per_testcase(negotiate_timeout_test, Config) ->
    test_util:setup(),
    meck_stream(server, test_stream),
    init_test_stream(server, test_util:setup_sock_pair(Config),
                     #{ negotiation_timeout => 300 });
init_per_testcase(_, Config) ->
    test_util:setup(),
    meck_stream(server, test_stream),
    init_test_stream(server, test_util:setup_sock_pair(Config), #{}).

end_per_testcase(_, Config) ->
    test_util:teardown_sock_pair(Config),
    meck_unload_stream(test_stream).

init_client_test_common(Config, AddModOpts) ->
    test_util:setup(),
    meck_stream(client, test_stream),
    init_test_stream(client, test_util:setup_sock_pair(Config), AddModOpts).

init_test_stream(Kind, Config, AddModOpts) ->
    {CSock, SSock} = ?config(client_server, Config),

    Handlers = [{"mplex/1.0.0", {no_mplex_mod, no_mplex_opts}},
                {"yamux/1.2.0", {no_yamux_mod, no_yamux_opts}},
                {"test_stream/1.0.0", {test_stream, #{}}}],
    StreamSock = case Kind of
                     server -> SSock;
                     client -> CSock
                 end,
    {ok, Pid} = libp2p_stream_tcp:start_link(Kind, #{socket => StreamSock,
                                                     handlers => Handlers,
                                                     mod_opts => AddModOpts
                                                    }),
    gen_tcp:controlling_process(StreamSock, Pid),
    [{stream, Pid} | Config].


%% Tests
%%

ls_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    handshake(client, CSock),

    %% Request list of supported protocols
    send_line(CSock, <<"ls">>),
    Lines = receive_lines(CSock),
    ?assert(lists:member(<<"mplex/1.0.0">>, Lines)),

    %% Fire random msg to ensure the streams stays up
    Pid ! random_msg,

    %% Ask for a non-supported protocol
    send_line(CSock, <<"not_found_protocol">>),
    ?assertEqual(<<"na">>, receive_line(CSock)),

    ok.

negotiate_server_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),

    handshake(client, CSock),

    SelectLine = <<"test_stream/1.0.0/extra/path">>,
    send_line(CSock, SelectLine),
    ?assertEqual(SelectLine, receive_line(CSock)),

    ok.

negotiate_client_test(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),

    handshake(server, SSock),

    ?assertEqual(<<"mplex/1.0.0">>, receive_line(SSock)),
    send_line(SSock, <<"na">>),
    ?assertEqual(<<"yamux/1.2.0">>, receive_line(SSock)),
    send_line(SSock, <<"na">>),
    ?assertEqual(<<"test_stream/1.0.0">>, receive_line(SSock)),
    send_line(SSock, <<"test_stream/1.0.0">>),

    ok.

handshake_client_reverse_test(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    %% Don't handshake from the server. The client should go into
    %% reverse handhsake mode so we handshake as a client.. on the
    %% server socket
    handshake(client, SSock),

    %% Fire random message to ensure the stream can deal with it.
    Pid ! random_msg,

    %% Request list of supported protocols
    send_line(SSock, <<"ls">>),
    Lines = receive_lines(SSock),
    ?assert(lists:member(<<"mplex/1.0.0">>, Lines)),

    ok.

%%
%% Negative tests
%%

negotiate_timeout_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    %% receive server handshake
    ?assertEqual(libp2p_stream_multistream:protocol_id(), receive_line(CSock)),
    %% Negotation time is set short for this test so the server will
    %% timeout and case the stream to stop
    ?assert(pid_should_die(Pid)),
    ok.

handshake_server_mismatch_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),

    Pid = ?config(stream, Config),

    %% receive server handshake
    ?assertEqual(libp2p_stream_multistream:protocol_id(), receive_line(CSock)),

    send_line(CSock, <<"bad_handshake">>),
    ?assert(pid_should_die(Pid)),

    ok.

handshake_client_mismatch_test(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),

    Pid = ?config(stream, Config),

    send_line(SSock, <<"bad_handshake">>),
    ?assert(pid_should_die(Pid)),

    ok.

handshake_client_reverse_fail_test(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    %% Receive the reverse handshake
    ?assertEqual(libp2p_stream_multistream:protocol_id(), receive_line(SSock)),
    %% Don't handshake, just send some random line
    send_line(SSock, <<"wut">>),

    ?assert(pid_should_die(Pid)),

    ok.

negotiate_client_fail_test(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    handshake(server, SSock),

    ?assertEqual(<<"mplex/1.0.0">>, receive_line(SSock)),
    send_line(SSock, <<"na">>),
    ?assertEqual(<<"yamux/1.2.0">>, receive_line(SSock)),
    send_line(SSock, <<"na">>),
    ?assertEqual(<<"test_stream/1.0.0">>, receive_line(SSock)),
    send_line(SSock, <<"na">>),

    ?assert(pid_should_die(Pid)),

    ok.

negotiate_client_mismatch_test(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    handshake(server, SSock),

    ?assertEqual(<<"mplex/1.0.0">>, receive_line(SSock)),
    send_line(SSock, <<"yamux/1.2.0">>),

    ?assert(pid_should_die(Pid)),

    ok.



%%
%% Utils
%%

pid_should_die(Pid) ->
    ok == test_util:wait_until(fun() ->
                                       not erlang:is_process_alive(Pid)
                               end).

handshake(client, Sock) ->
    %% receive server handshake
    ProtocolId = libp2p_stream_multistream:protocol_id(),
    HandshakeSize = byte_size(libp2p_stream_multistream:encode_line(ProtocolId)),
    ?assertEqual(ProtocolId, receive_line(Sock, HandshakeSize)),
    %% Send client handshake
    send_line(Sock, ProtocolId);
handshake(server, Sock) ->
    ProtocolId = libp2p_stream_multistream:protocol_id(),
    HandshakeSize = byte_size(libp2p_stream_multistream:encode_line(ProtocolId)),
    %% send server handshake
    send_line(Sock, ProtocolId),
    %% receive client handshake
    ?assertEqual(libp2p_stream_multistream:protocol_id(), receive_line(Sock, HandshakeSize)).


send_line(Sock, Line) ->
    Bin = libp2p_stream_multistream:encode_line(Line),
    ok = gen_tcp:send(Sock, Bin).

receive_line(Sock) ->
    receive_line(Sock, 0).

receive_line(Sock, Size) ->
    {ok, Bin} = gen_tcp:recv(Sock, Size, 500),
    {Line, _Rest} = libp2p_stream_multistream:decode_line(Bin),
    Line.

receive_lines(Sock) ->
    {ok, Bin} = gen_tcp:recv(Sock, 0, 500),
    libp2p_stream_multistream:decode_lines(Bin).


%%
%% Utilities
%%

encode_packet(Data) ->
    DataSize = byte_size(Data),
    libp2p_packet:encode_packet([u8], [DataSize], Data).

send_packet(Sock, Data) ->
    Packet = encode_packet(Data),
    ok = gen_tcp:send(Sock, Packet).

receive_packet(Sock) ->
    {ok, Bin} = gen_tcp:recv(Sock, 0, 500),
    {ok, [DataSize], Data, <<>>} = libp2p_packet:decode_packet([u8], Bin),
    ?assertEqual(DataSize, byte_size(Data)),
    Data.


meck_stream(server, Name) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, init,
                fun(server, Opts=#{stop := {send, Reason, Data}}) ->
                        Packet = encode_packet(Data),
                        {stop, Reason, Opts, [{send, Packet}]};
                   (server, #{stop := Reason}) ->
                        {stop, Reason};
                   (server, Opts) ->
                        {ok, Opts, [{packet_spec, [u8]},
                                    {active, once}
                                   ]}
                end),
    meck:expect(Name, handle_packet,
               fun(server, _, Data, State) ->
                       Packet = encode_packet(Data),
                       {noreply, State, [{send, Packet}]}
               end),
    ok;
meck_stream(client, Name) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, init,
                fun(client, Opts=#{stop := {send, Reason, Data}}) ->
                        Packet = encode_packet(Data),
                        {stop, Reason, Opts, [{send, Packet}]};
                   (client, #{stop := Reason}) ->
                        {stop, Reason};
                   (client, Opts) ->
                        {ok, Opts, [{packet_spec, [u8]},
                                    {active, once}
                                   ]}
                end),
    meck:expect(Name, handle_packet,
               fun(client, _, Data, State) ->
                       Packet = encode_packet(Data),
                       {noreply, State, [{send, Packet}]}
               end),
    ok.


meck_unload_stream(Name) ->
    meck:unload(Name).
