-module(stream_mplex_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     open_test
    ].

init_per_testcase(_, Config) ->
    test_util:setup(),
    meck_stream(server, test_stream_server),
    meck_stream(client, test_stream_client),
    init_test_streams(test_util:setup_sock_pair(Config)).

end_per_testcase(_, Config) ->
    test_util:teardown_sock_pair(Config),
    meck_unload_stream(test_stream_server),
    meck_unload_stream(test_stream_client).

init_test_streams(Config) ->
    {CSock, SSock} = ?config(client_server, Config),

    %% Server muxer
    ServerStreamOpts = #{ mod => test_stream_server },
    ServerModOpts = #{ mod_opts => ServerStreamOpts },
    {ok, SPid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                        mod => libp2p_stream_mplex,
                                                        mod_opts => ServerModOpts
                                                    }),
    gen_tcp:controlling_process(SSock, SPid),

    %% Client muxer
    ClientStreamOpts = #{ mod => test_stream_client },
    ClientModOpts = #{ mod_opts => ClientStreamOpts },
    {ok, CPid} = libp2p_stream_tcp:start_link(client, #{socket => CSock,
                                                        mod => libp2p_stream_mplex,
                                                        mod_opts => ClientModOpts
                                                       }),
    gen_tcp:controlling_process(CSock, CPid),

    [{stream_client_server, {CPid, SPid}} | Config].


%% Tests
%%

open_test(Config) ->
    {CMPid, _SMPid} = ?config(stream_client_server, Config),

    {ok, CPid} = libp2p_stream_muxer:open(CMPid),

    ?assert(erlang:is_process_alive(CPid)),

    ?assertEqual(<<"hello">>, libp2p_stream_transport:command(CPid, {send, <<"hello">>})),

    ok.


%%
%% Utilities
%%
encode_packet(Data) ->
    DataSize = byte_size(Data),
    libp2p_packet:encode_packet([u8], [DataSize], Data).


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
                       {noreply, State,
                        [{send, Packet},
                         {active, once}]}
               end),
    ok;
meck_stream(client, Name) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, init,
                fun(client, Opts=#{stop := {send, Reason, Data}}) ->
                        Packet = encode_packet(Data),
                        {stop, Reason, Opts,
                         [{send, Packet}]};
                   (client, #{stop := Reason}) ->
                        {stop, Reason};
                   (client, Opts) ->
                        {ok, Opts,
                         [{packet_spec, [u8]},
                          {active, once}
                         ]}
                end),
    meck:expect(Name, handle_command,
               fun(client, {send, Data}, From, State) ->
                       {noreply, State#{sender => From},
                       [{send, encode_packet(Data)},
                        {timer, send_response_timeout, 1000}]}
               end),
    meck:expect(Name, handle_info,
               fun(client, {timeout, send_response_timeout}, State=#{sender := Sender}) ->
                       {noreply, maps:remove(sender, State),
                        [{reply, Sender, {error, timeout}}]}
               end),
    meck:expect(Name, handle_packet,
               fun(client, _, Data, State=#{sender := Sender}) ->
                       {noreply, maps:remove(sender, State),
                        [{reply, Sender, Data},
                         {active, once}]}
               end),
    ok.


meck_unload_stream(Name) ->
    meck:unload(Name).
