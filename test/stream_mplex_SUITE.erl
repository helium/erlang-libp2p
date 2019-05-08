-module(stream_mplex_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     open_test,
     reset_client_test,
     reset_server_test,
     close_client_test,
     shutdown_client_test,
     exit_client_test,
     max_received_test
    ].

init_per_testcase(max_received_test, Config) ->
    test_util:setup(),
    meck_stream(test_stream_server),
    meck_stream(test_stream_client),
    init_test_streams(test_util:setup_sock_pair(Config),
                      #{max_received_streams => 0});
init_per_testcase(_, Config) ->
    test_util:setup(),
    meck_stream(test_stream_server),
    meck_stream(test_stream_client),
    init_test_streams(test_util:setup_sock_pair(Config), #{}).

end_per_testcase(_, Config) ->
    test_util:teardown_sock_pair(Config),
    meck_unload_stream(test_stream_server),
    meck_unload_stream(test_stream_client).

init_test_streams(Config, MuxerOpts) ->
    {CSock, SSock} = ?config(client_server, Config),

    %% Server muxer
    ServerStreamOpts = #{ mod => test_stream_server },
    ServerModOpts = maps:merge(#{ mod_opts => ServerStreamOpts },
                               MuxerOpts),
    {ok, SPid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                        mod => libp2p_stream_mplex,
                                                        mod_opts => ServerModOpts
                                                    }),
    gen_tcp:controlling_process(SSock, SPid),

    %% Client muxer
    ClientStreamOpts = #{ mod => test_stream_client },
    ClientModOpts = maps:merge(#{ mod_opts => ClientStreamOpts },
                               MuxerOpts),
    {ok, CPid} = libp2p_stream_tcp:start_link(client, #{socket => CSock,
                                                        mod => libp2p_stream_mplex,
                                                        mod_opts => ClientModOpts
                                                       }),
    gen_tcp:controlling_process(CSock, CPid),

    [{stream_client_server, {CPid, SPid}} | Config].


%% Tests
%%


%% Create a mplex stream, set up with a simple echo worker handler
%% mod. Opening the stream should leave an echo service in place.
open_test(Config) ->
    {CMPid, SMPid} = ?config(stream_client_server, Config),

    %% Check that there are no streams for either on startop
    ?assertMatch({ok, []}, libp2p_stream_muxer:streams(CMPid, client)),
    ?assertMatch({ok, []}, libp2p_stream_muxer:streams(SMPid, server)),

    %% Open a stream, ensure client knows about it
    {ok, CPid} = libp2p_stream_muxer:open(CMPid),
    ?assertMatch({ok, [CPid]}, libp2p_stream_muxer:streams(CMPid, client)),
    %% and that it has no "server" streams
    ?assertMatch({ok, []}, libp2p_stream_muxer:streams(CMPid, server)),

    %% Wait for the server muxer to know about it's side of the stream
    {ok, [SPid]} = streams(SMPid, server),
    %% and that the server muxer has no client streams
    ?assertMatch({ok, []}, libp2p_stream_muxer:streams(SMPid, client)),

    %% Send from client to server
    CPid ! {send, <<"hello">>},
    ?assertEqual(<<"hello">>, stream_cmd(SPid, recv)),

    %% Send from server to client
    SPid ! {send, <<"world">>},
    ?assertEqual(<<"world">>, stream_cmd(CPid, recv)),
    ok.


reset_client_test(Config) ->
    {CMPid, SMPid} = ?config(stream_client_server, Config),

    {ok, CPid} = libp2p_stream_muxer:open(CMPid),

    %% Wait for server to know about the stream so we can check that a
    %% reset stops both sides.
    {ok, [SPid]} = streams(SMPid, server),
    %% Reset the client
    libp2p_stream_mplex_worker:reset(CPid),
    %% both client and server streams should go away
    ?assert(pid_should_die(CPid)),
    ?assert(pid_should_die(SPid)),

    ok.

reset_server_test(Config) ->
    {CMPid, SMPid} = ?config(stream_client_server, Config),

    {ok, CPid} = libp2p_stream_muxer:open(CMPid),

    %% Wait for server to know about the stream so we can check that a
    %% reset stops both sides.
    {ok, [SPid]} = streams(SMPid, server),
    %% Reset server stream
    libp2p_stream_mplex_worker:reset(SPid),
    %% both client and server streams should go away
    ?assert(pid_should_die(CPid)),
    ?assert(pid_should_die(SPid)),

    ok.

shutdown_client_test(Config) ->
    {CMPid, SMPid} = ?config(stream_client_server, Config),

    {ok, CPid} = libp2p_stream_muxer:open(CMPid),
    {ok, [SPid]} = streams(SMPid, server),

    %% Shutting down a client stream should shut down both sides.
    exit(CPid, shutdown),

    pid_should_die(CPid),
    pid_should_die(SPid),

    ok.

exit_client_test(Config) ->
    {CMPid, SMPid} = ?config(stream_client_server, Config),

    {ok, CPid} = libp2p_stream_muxer:open(CMPid),
    {ok, [SPid]} = streams(SMPid, server),

    %% Crashing a stream should shut down both sides.
    exit(CPid, abornal_exit),

    ?assert(pid_should_die(CPid)),
    ?assert(pid_should_die(SPid)),

    ok.


close_client_test(Config) ->
    {CMPid, SMPid} = ?config(stream_client_server, Config),

    {ok, CPid} = libp2p_stream_muxer:open(CMPid),

    {ok, [SPid]} = streams(SMPid, server),

    %% Send packet from client and close it for writing
    CPid ! {send, <<"last_client_write">>},
    libp2p_stream_mplex_worker:close(CPid),
    ?assert(close_state_should_be(CPid, write)),
    ?assert(close_state_should_be(SPid, read)),

    %% Check server receives the last client packet
    ?assertEqual(<<"last_client_write">>, stream_cmd(SPid, recv)),
    %% And can send data that is received by the client stream
    SPid ! {send, <<"last_server_write">>},
    ?assertEqual(<<"last_server_write">>, stream_cmd(CPid, recv)),

    %% Close the server, which will then close both sides
    libp2p_stream_mplex_worker:close(SPid),

    ?assert(pid_should_die(CPid)),
    ?assert(pid_should_die(SPid)),

    ok.

max_received_test(Config) ->
    {CMPid, _SMPid} = ?config(stream_client_server, Config),
    {ok, CPid} = libp2p_stream_muxer:open(CMPid),

    ?assert(pid_should_die(CPid)),

    ok.

%%
%% Utilities
%%

pid_should_die(Pid) ->
    ok == test_util:wait_until(fun() ->
                                       not erlang:is_process_alive(Pid)
                               end).

close_state_should_be(Pid, CloseState) ->
    ok == test_util:wait_until(fun() ->
                                       {ok, CloseState} == libp2p_stream_mplex_worker:close_state(Pid)
                               end).


streams(MuxPid, Kind) ->
    ok = test_util:wait_until(fun() ->
                                      {ok, ServerStreams} = libp2p_stream_muxer:streams(MuxPid, Kind),
                                      length(ServerStreams) > 0
                              end),
    libp2p_stream_muxer:streams(MuxPid, Kind).

stream_cmd(StreamPid, Cmd) ->
    libp2p_stream_transport:command(StreamPid, Cmd).


encode_packet(Data) ->
    DataSize = byte_size(Data),
    libp2p_packet:encode_packet([u8], [DataSize], Data).


meck_stream(Name) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, init,
                fun(_, Opts) ->
                        {ok, Opts,
                         [{packet_spec, [u8]},
                          {active, once}
                         ]}
                end),
    meck:expect(Name, handle_command,
               fun(_Kind, recv, _From, State=#{last_packet := LastData}) ->
                       {reply, LastData, maps:remove(last_packet, State),
                       [{active, once}]};
                  (_, recv, From, State=#{}) ->
                       {noreply, State#{receiver => From},
                        [{active, once},
                         {timer, receive_response_timeout, 1000}
                        ]}
               end),
    meck:expect(Name, handle_info,
                fun(_, {send, Data}, State) ->
                        {noreply, State,
                         [{send, encode_packet(Data)},
                          {active, once}]};
                   (_, {timeout, receive_response_timeout}, State=#{receiver := Receiver}) ->
                       {noreply, maps:remove(receiver, State),
                        [{reply, Receiver, {error, timeout}}]}
                end),
    meck:expect(Name, handle_packet,
               fun(_, _, Data, State=#{receiver := Receiver}) ->
                       {noreply, maps:remove(sender, State),
                        [{reply, Receiver, Data},
                         {cancel_timer, receive_response_timeout},
                         {active, once}]};
                  (_Kind, _, Data, State) ->
                       {noreply, State#{last_packet => Data},
                        [{cancel_timer, receive_response_timeout}]}
               end),
    ok.


meck_unload_stream(Name) ->
    meck:unload(Name).
