-module(stream_tcp_SUITE).

-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     init_close_test,
     init_close_send_test,
     init_ok_test
    ].


mk_client_server(Config) when is_list(Config) ->
    LSock = proplists:get_value(listen_sock, Config),
    mk_client_server(LSock);
mk_client_server(LSock) ->
    Parent = self(),
    spawn(fun() ->
                  {ok, ServerSock} = gen_tcp:accept(LSock),
                  gen_tcp:controlling_process(ServerSock, Parent),
                  Parent ! {accepted, ServerSock}
          end),
    {ok, LPort} = inet:port(LSock),
    {ok, CSock} = gen_tcp:connect("localhost", LPort, [binary,
                                                       {active, false},
                                                       {packet, raw},
                                                       {nodelay, true}]),
    receive
        {accepted, SSock} -> SSock
    end,
    {CSock, SSock}.


init_per_testcase(_, Config) ->
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),

    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}]),
    {CSock, SSock} = mk_client_server(LSock),
    [{listen_sock, LSock}, {client_server, {CSock, SSock}} | Config].

end_per_testcase(_, Config) ->
    gen_tcp:close(proplists:get_value(listen_sock, Config)),
    {CSock, SSock} = proplists:get_value(client_server, Config),
    gen_tcp:close(CSock),
    gen_tcp:close(SSock),
    ok.


meck_stream() ->
    meck:new(test_stream, [non_strict]),
    meck:expect(test_stream, init,
                fun(server, Opts=#{init_type := echo}) ->
                        {ok, Opts, [{packet_spec, [u8]},
                                    {active, once}
                                   ]};
                   (server, #{init_type := {close, Reason}}) ->
                        {close, Reason};
                   (server, Opts=#{init_type := {close_send, Reason, Data}}) ->
                        {close, Reason, Opts, [{send, Data}]}
                end),
    meck:expect(test_stream, handle_packet,
               fun(server, _, Data, State) ->
                       Packet = libp2p_packet:encode_packet([u8], [byte_size(Data)], Data),
                       {ok, State, [{send, Packet}, {active, once}]}
               end),
    meck:expect(test_stream, handle_info,
               fun(server, no_action, State=#{}) ->
                       {ok, State}
               end),
    ok.


meck_unload_stream() ->
    meck:unload(test_stream).

init_close_send_test(Config) ->
    meck_stream(),

    {CSock, SSock} = proplists:get_value(client_server, Config),

    CloseData = <<"hello">>,
    StartResult = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                         mod => test_stream,
                                                         mod_opts =>
                                                             #{ init_type => {close_send,
                                                                              normal,
                                                                              CloseData}}
                                                        }),

    %% Since terminate doesn't get called on a close on startup, close
    %% the server socket here
    gen_tcp:close(SSock),

    ?assertEqual({ok, CloseData}, gen_tcp:recv(CSock, 0)),
    ?assertEqual({error, normal}, StartResult),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0)),

    meck_unload_stream(),
    ok.

init_close_test(Config) ->
    meck_stream(),

    {CSock, SSock} = proplists:get_value(client_server, Config),

    StartResult = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                         mod => test_stream,
                                                         mod_opts =>
                                                             #{ init_type => {close, normal} }
                                                        }),

    %% Since terminate doesn't get called on a close on startup, close
    %% the server socket here
    gen_tcp:close(SSock),

    ?assertEqual({error, normal}, StartResult),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0)),

    meck_unload_stream(),
    ok.

init_ok_test(Config) ->
    meck_stream(),

    {CSock, SSock} = proplists:get_value(client_server, Config),

    {ok, Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                       mod => test_stream,
                                                       mod_opts => #{ init_type => echo }
                                                      }),

    gen_tcp:controlling_process(SSock, Pid),

    Data = <<"hello">>,
    DataSize = byte_size(Data),
    Packet = libp2p_packet:encode_packet([u8], [DataSize], Data),
    ok = gen_tcp:send(CSock, Packet),

    {ok, Bin} = gen_tcp:recv(CSock, 0),
    ?assertEqual({ok, [DataSize], Data, <<>>}, libp2p_packet:decode_packet([u8], Bin)),

    meck_unload_stream(),
    ok.
