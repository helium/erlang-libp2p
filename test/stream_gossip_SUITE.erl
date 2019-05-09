-module(stream_gossip_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     gossip_accept_test,
     gossip_reject_test,
     gossip_crash_test
    ].

init_per_testcase(gossip_reject_test, Config) ->
    meck_gossip_handler(gossip_handler_server, {error, rejected}),
    init_common(Config);
init_per_testcase(gossip_crash_test, Config) ->
    meck_gossip_handler(gossip_handler_server, {exit, just_another_crash}),
    init_common(Config);
init_per_testcase(_, Config) ->
    meck_gossip_handler(gossip_handler_server, ok),
    init_streams(init_common(Config)).

end_per_testcase(_, Config) ->
    test_util:teardown_sock_pair(Config),
    meck_unload_gossip_handler(gossip_handler_server),
    meck_unload_gossip_handler(gossip_handler_client),
    ok.

init_common(Config) ->
    test_util:setup(),
    meck_gossip_handler(gossip_handler_client, ok),
    test_util:setup_sock_pair(Config).

init_server_stream(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),

    case libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                mod => libp2p_stream_gossip,
                                                mod_opts => #{ handler_mod => gossip_handler_server,
                                                               handler_state => undefined }
                                               }) of
        {ok, SPid} ->
            gen_tcp:controlling_process(SSock, SPid),
            {ok, SPid};
        Other ->
            Other
    end.


init_streams(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),

    {ok, SPid} = init_server_stream(Config),

    %% Client muxer
    {ok, CPid} = libp2p_stream_tcp:start_link(client, #{socket => CSock,
                                                        mod => libp2p_stream_gossip,
                                                        mod_opts => #{ handler_mod => gossip_handler_client,
                                                                       handler_state => undefined }
                                                       }),
    gen_tcp:controlling_process(CSock, CPid),

    [{stream_client_server, {CPid, SPid}} | Config].

%%
%% Tests
%%


gossip_accept_test(Config) ->
    {CPid, _SPid} = ?config(stream_client_server, Config),

    Parent = self(),
    meck:expect(gossip_handler_server, handle_gossip_data,
                fun(_, Key, Data) ->
                        Parent ! {handle_gossip_data, Key, Data},
                        ok
                end),
    CPid ! {send, "test_gossip", <<"hello_world">>},
    receive
        {handle_gossip_data, Key, Data} ->
            ?assertEqual("test_gossip", Key),
            ?assertEqual(<<"hello_world">>, Data)
    after 1000 ->
            ct:fail(gossip_receive_timeout)
    end,

    %% Toss an unhandlded info for good measure (and vanity coverage)
    CPid ! unhandled_msg,

    ok.

gossip_reject_test(Config) ->
    %% A rejected gossip stream will still exit normal to avoid
    %% spamming logs with crashes.
    ?assertEqual({error, normal}, init_server_stream(Config)).

gossip_crash_test(Config) ->
    %% A rejected gossip stream will still exit normal to avoid
    %% spamming logs with crashes.
    ?assertEqual({error, normal}, init_server_stream(Config)).

%%
%% Utils
%%

meck_gossip_handler(Name, AcceptStreamResponse) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, accept_gossip_stream,
                fun(_, _, _) ->
                        case AcceptStreamResponse of
                            {exit, Reason} ->
                                exit(Reason);
                            Other ->
                                Other
                        end
                end).

meck_unload_gossip_handler(Name) ->
    meck:unload(Name).
