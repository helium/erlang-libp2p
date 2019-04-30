-module(stream_tcp_SUITE).


all() ->
    [
     init_test
    ].

init_per_testcase(_, Config) ->
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),

    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, LPort} = inet:port(LSock),
    Parent = self(),
    spawn(fun() ->
                  {ok, ServerSock} = gen_tcp:accept(LSock),
                  Parent ! {accepted, ServerSock}
          end),
    {ok, CSock} = gen_tcp:connect("localhost", LPort, [binary, {packet, raw}, {nodelay, true}]),
    receive
        {accepted, SSock} -> SSock
    end,
    [{listen_sock, LSock},
     {listen_port, LPort},
     {server_sock, SSock},
     {client_sock, CSock} | Config].

end_per_testcase(_, Config) ->
    gen_tcp:close(proplists:get_value(client_sock, Config)),
    gen_tcp:close(proplists:get_value(server_sock, Config)),
    gen_tcp:close(proplists:get_value(listen_sock, Config)),

    ok.


meck_echo_stream() ->
    meck:new(test_echo_stream, [non_strict]),
    meck:expect(test_echo_stream, init,
                fun(server, Opts=#{send_fn := _,
                                   echo_count := _ }) ->
                        {ok, Opts, [{packet_spec, u8},
                                    {active, once}]}
                end),
    meck:expect(test_echo_stream, handle_packet,
               fun(server, _, Data, State=#{}) ->
                       Packet = libp2p_packet:encode_packet([u8], [byte_size(Data)], Data),
                       {ok, State, [{send, Packet}]}
               end),
    ok.


init_test(Config) ->
    meck_echo_stream(),

    SSock = proplists:get_value(server_sock, Config),
    CSock = proplists:get_value(client_sock, Config),

    {ok, _Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                        mod => test_echo_stream,
                                                        mod_opts => #{ echo_count => 1}}),

    Data = <<"hello">>,
    DataSize = byte_size(Data),
    ok = gen_tcp:send(CSock, libp2p_packet:encode_packet([u8], [DataSize], Data)),

    {ok, Bin} = gen_tcp:recv(CSock, 0),
    {ok, [DataSize], Data} = libp2p_packet:decode_packet([u8], Bin),

    ok.
