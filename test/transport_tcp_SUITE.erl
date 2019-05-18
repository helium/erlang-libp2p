-module(transport_tcp_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     connect_test,
     dial_test
    ].

init_per_testcase(_, Config) ->
    test_util:setup(),
    meck_stream(test_stream),
    Name = list_to_atom("swarm" ++ integer_to_list(erlang:monotonic_time())),
    TID = ets:new(Name, [public, ordered_set, {read_concurrency, true}]),

    ets:insert(TID, {swarm_name, Name}),

    StreamHandlerFun = fun() ->
                               libp2p_config:lookup_stream_handlers(TID)
                       end,
    libp2p_swarm:add_connection_handler(TID, {libp2p_stream_mplex:protocol_id(),
                                              {libp2p_stream_mplex, #{ handler_fn => StreamHandlerFun}}}),

    {ok, ListenerSup} = libp2p_swarm_listener_sup:start_link(TID),
    unlink(ListenerSup),
    {ok, SessionSup} = libp2p_swarm_session_sup:start_link(TID),
    unlink(SessionSup),

    {ok, Pid} = libp2p_transport_tcp:start_link(TID),
    {ok, _, _ListenPid} = libp2p_transport_tcp:start_listener(Pid, "/ip4/0.0.0.0/tcp/0"),
    [MAddr | _] = libp2p_config:listen_addrs(TID),

    [{transport, Pid},
     {tid, TID},
     {session_sup, SessionSup},
     {listener_sup, ListenerSup},
     {listen_addr, MAddr}
     | Config].

end_per_testcase(_, Config) ->
    Pids = [?config(transport, Config),
            ?config(session_sup, Config),
            ?config(listener_sup, Config)],
    lists:foreach(fun(Pid) -> exit(Pid, normal) end, Pids),
    meck_unload_stream(test_stream).




%%
%% Tests
%%

connect_test(Config) ->
    Pid = ?config(transport, Config),
    TID = ?config(tid, Config),
    ListenAddr = ?config(listen_addr, Config),

    ConnectOpts = #{ tid => TID,
                     unique_session => true,
                     stream_handler => {self(), undefined}},
    {ok, Muxer} = libp2p_transport_tcp:connect(Pid, ListenAddr, ConnectOpts),

    receive
        {stream_muxer, _, ConnectedMuxer} ->
            ?assertEqual(Muxer, ConnectedMuxer)
    after 5000 ->
            ?assert(false)
    end,

    ?assertEqual({ok, []}, libp2p_stream_muxer:streams(Muxer, client)),

    ok.

dial_test(Config) ->
    Pid = ?config(transport, Config),
    TID = ?config(tid, Config),
    ListenAddr = ?config(listen_addr, Config),

    Handler = {<<"stream/1.0.0">>, {test_stream, #{ parent => self() }}},
    libp2p_config:insert_stream_handler(TID, Handler),

    ConnectOpts = #{ tid => TID,
                     unique_session => true },
    {ok, Muxer} = libp2p_transport_tcp:dial(Pid, ListenAddr, ConnectOpts, Handler),

    receive
        stream_init -> ok
    after 5000 ->
            ?assert(false)
    end,

    ?assertMatch({ok, [_]}, libp2p_stream_muxer:streams(Muxer, client)),

    ok.


%%
%% Utilities
%%

meck_stream(Name) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, init,
                fun(_, Opts=#{ parent := Parent}) ->
                        Parent ! stream_init,
                        {ok, Opts,
                         [{packet_spec, [u8]},
                          {active, once}
                         ]}
                end),
    ok.


meck_unload_stream(Name) ->
    meck:unload(Name).
