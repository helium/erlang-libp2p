-module(stream_tcp_SUITE).

 -include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     init_stop_test,
     init_stop_send_test,
     init_ok_test,
     info_test,
     command_test
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
    test_util:setup(),
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
                   (server, #{init_type := {stop, Reason}}) ->
                        {stop, Reason};
                   (server, Opts=#{init_type := {stop_send, Reason, Data}}) ->
                        Packet = encode_packet(Data),
                        {stop, Reason, Opts, [{send, Packet}]}
                end),
    meck:expect(test_stream, handle_packet,
               fun(server, _, Data, State) ->
                       Packet = encode_packet(Data),
                       {noreply, State, [{send, Packet}, {active, once}]}
               end),
    ok.


meck_unload_stream() ->
    meck:unload(test_stream).

init_stop_send_test(Config) ->
    meck_stream(),

    {CSock, SSock} = ?config(client_server, Config),

    StartResult = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                         mod => test_stream,
                                                         mod_opts =>
                                                             #{ init_type => {stop_send,
                                                                              normal,
                                                                              <<"hello">>}}
                                                        }),

    %% Since terminate doesn't get called on a close on startup, close
    %% the server socket here
    gen_tcp:close(SSock),

    ?assertEqual(<<"hello">>, receive_packet(CSock)),
    ?assertEqual({error, normal}, StartResult),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0, 0)),

    meck_unload_stream(),
    ok.

init_stop_test(Config) ->
    meck_stream(),

    {CSock, SSock} = ?config(client_server, Config),

    StartResult = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                         mod => test_stream,
                                                         mod_opts =>
                                                             #{ init_type => {stop, normal} }
                                                        }),

    %% Since terminate doesn't get called on a close on startup, close
    %% the server socket here
    gen_tcp:close(SSock),

    ?assertEqual({error, normal}, StartResult),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0, 0)),

    meck_unload_stream(),
    ok.


encode_packet(Data) ->
    DataSize = byte_size(Data),
    libp2p_packet:encode_packet([u8], [DataSize], Data).

send_packet(Sock, Data) ->
    Packet = encode_packet(Data),
    ok = gen_tcp:send(Sock, Packet).


receive_packet(Sock) ->
    {ok, Bin} = gen_tcp:recv(Sock, 0),
    {ok, [DataSize], Data, <<>>} = libp2p_packet:decode_packet([u8], Bin),
    ?assertEqual(DataSize, byte_size(Data)),
    Data.

init_ok_test(Config) ->
    meck_stream(),

    {CSock, SSock} = ?config(client_server, Config),

    {ok, Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                       mod => test_stream,
                                                       mod_opts => #{ init_type => echo }
                                                      }),

    gen_tcp:controlling_process(SSock, Pid),

    send_packet(CSock, <<"hello">>),
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    meck_unload_stream(),
    ok.

sock_close_test(Config) ->
    meck_stream(),

    {CSock, SSock} = ?config(client_server, Config),
    {ok, Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                       mod => test_stream,
                                                       mod_opts => #{ init_type => echo }
                                                      }),
    gen_tcp:controlling_process(SSock, Pid),
    gen_tcp:close(CSock),

    ok = test_util:wait_until(fun() ->
                                      not erlang:is_process_alive(Pid)
                              end),

    ok.


info_test(Config) ->
    meck_stream(),

    {CSock, SSock} = ?config(client_server, Config),

    {ok, Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                       mod => test_stream,
                                                       mod_opts => #{ init_type => echo }
                                                      }),
    gen_tcp:controlling_process(SSock, Pid),

    Pid ! no_handler,

    meck:expect(test_stream, handle_info,
               fun(server, {send, Data}, State) ->
                       Packet = encode_packet(Data),
                       {noreply, State, [{send, Packet}]};
                  (server, no_actions, State) ->
                       {noreply, State};
                  (server, multi_active, State) ->
                       %% Excercise same action having no effect
                       {noreply, State, [{active, once}, {active, once}]};
                  (server, {stop, Reason}, State) ->
                       {stop, Reason, State}
               end),

    Pid ! {send, <<"hello">>},
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    Pid ! no_actions,
    Pid ! multi_active,
    Pid ! {stop, normal},

    ok = test_util:wait_until(fun() ->
                                      not erlang:is_process_alive(Pid)
                              end),

    meck_unload_stream(),
    ok.

command_test(Config) ->
    meck_stream(),

    {CSock, SSock} = ?config(client_server, Config),

    {ok, Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                       mod => test_stream,
                                                       mod_opts => #{ init_type => echo }
                                                      }),
    gen_tcp:controlling_process(SSock, Pid),

    ?assertEqual(ok, libp2p_stream_transport:command(Pid, no_implementation)),

    meck:expect(test_stream, handle_command,
               fun(server, {send, Data}, _From, State) ->
                       Packet = encode_packet(Data),
                       {reply, send, State, [{send, Packet}]};
                  (server, no_action, _From, State) ->
                       {reply, no_action, State};
                  (server, noreply_no_action, From, State) ->
                       {noreply, State#{noreply_from => From}};
                  (server, reply_noreply, _From, State=#{noreply_from := NoReplyFrom}) ->
                       {reply, ok, State, [{reply, NoReplyFrom, reply_noreply}]};
                  (_, swap_kind, _From, State) ->
                       {reply, ok, State, [swap_kind]};
                  (Kind, kind, _From, State) ->
                       {reply, Kind, State}
               end),

    ?assertEqual(no_action, libp2p_stream_tcp:command(Pid, no_action)),

    %% Call a command with noreply in a new pid
    Parent = self(),
    spawn(fun() ->
                  Reply = libp2p_stream_tcp:command(Pid, noreply_no_action),
                  Parent ! {noreply_reply, Reply}
          end),
    %% Let the spawned function run
    timer:sleep(100),
    %% Now get it to reply with a reply action
    ?assertEqual(ok, libp2p_stream_tcp:command(Pid, reply_noreply)),

    receive
        {noreply_reply, reply_noreply} -> ok
    after 500 ->
            ?assert(timeout_noreply_reply)
    end,

    ?assertEqual(send, libp2p_stream_tcp:command(Pid, {send, <<"hello">>})),
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    %% Swap kind to client and back
    ?assertEqual(ok, libp2p_stream_tcp:command(Pid, swap_kind)),
    ?assertEqual(client, libp2p_stream_tcp:command(Pid, kind)),
    ?assertEqual(ok, libp2p_stream_tcp:command(Pid, swap_kind)),
    ?assertEqual(server, libp2p_stream_tcp:command(Pid, kind)),

    ok.
