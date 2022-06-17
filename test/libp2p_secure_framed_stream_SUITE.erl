-module(libp2p_secure_framed_stream_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    invalid_key_exchange/1,
    key_exchange/1,
    stream/1,
    failed_stream/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [invalid_key_exchange, key_exchange, stream, failed_stream].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    test_util:setup(),
    lager:set_loglevel(lager_console_backend, debug),
    Config0.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
invalid_key_exchange(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}, {libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}],
    Version = "securetest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(insecure_server_test, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_secure_framed_stream_echo_test, self(), ServerSwarm, {secured, ServerSwarm}]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(insecure_client_test, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),

    LAs = libp2p_swarm:listen_addrs(ServerSwarm),
    [ServerAddress|_] = LAs,
    ServerP2P = libp2p_swarm:p2p_address(ServerSwarm),

    % Dialing here to propagate peerbook
    {ok, ClientStream0} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        ServerAddress,
        Version,
        libp2p_secure_framed_stream_echo_test,
        [ClientSwarm, self()]
    ),

    PeerBook = libp2p_swarm:peerbook(ClientSwarm),
    ServerPeerbookAddr = libp2p_swarm:pubkey_bin(ServerSwarm),
    timer:sleep(1000),

    ok = test_util:wait_until(fun() ->
                                      ok == element(1, libp2p_peerbook:get(PeerBook, ServerPeerbookAddr))
                              end),

    gen_server:stop(ClientStream0),

    ok = libp2p_swarm:stop(ServerSwarm),

    %% start another swarm on the same address
    {ok, EvilSwarm} = libp2p_swarm:start(insecure_evil_test, SwarmOpts),
    [ok = libp2p_swarm:listen(EvilSwarm, LA) || LA <- LAs],
    libp2p_swarm:add_stream_handler(
        EvilSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_secure_framed_stream_echo_test, self(), EvilSwarm, {secured, EvilSwarm}]}
     ),

    try

    ok = test_util:wait_until(
           fun() ->
                   %% this should fail because the swarm on the other end is not who we think it is
                   {error, incorrect_peer} == libp2p_swarm:dial_framed_stream(
                                                ClientSwarm,
                                                ServerP2P,
                                                Version,
                                                libp2p_secure_framed_stream_echo_test,
                                                [ClientSwarm, self(), {secured, ClientSwarm}]
                                               )
           end, 45, 1000)

    after
        ok = libp2p_swarm:stop(EvilSwarm),
        ok = libp2p_swarm:stop(ClientSwarm)
    end,
    ok.

key_exchange(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]},{libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}],
    Version = "securetest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(secure_server_test, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_secure_framed_stream_test, self(), ServerSwarm]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(secure_client_test, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),

    [ServerAddress|_] = libp2p_swarm:listen_addrs(ServerSwarm),
    {ok, ClientStream} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        ServerAddress,
        Version,
        libp2p_secure_framed_stream_test,
        [ClientSwarm, self()]
    ),

    ok = test_util:wait_until(fun() -> true =:= gen_server:call(ClientStream, exchanged) end),
    ?assert(gen_server:call(ClientStream, exchanged)),

    lists:foreach(
        fun(_) ->
            Data = crypto:strong_rand_bytes(16),
            ClientStream ! {send, Data},
            receive
                {echo, server, Data} ->
                    ok;
                _Else -> ct:fail(_Else)
            after 250 ->
                ct:fail(timeout)
            end
        end,
        lists:seq(1, 100)
    ),

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ClientSwarm),
    ok.

stream(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}, {libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}],
    Version = "securetest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(secure_server_echo_test, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_secure_framed_stream_echo_test, self(), {secured, ServerSwarm}]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(secure_client_echo_test, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),

    [ServerAddress|_] = libp2p_swarm:listen_addrs(ServerSwarm),

    % Dialing here to propagate peerbook
    {ok, ClientStream0} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        ServerAddress,
        Version,
        libp2p_secure_framed_stream_echo_test,
        [self()]
    ),
    timer:sleep(2000),

    % Check is not dialing p2p = fail
    {error, secured_not_dialing_p2p} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        ServerAddress,
        Version,
        libp2p_secure_framed_stream_echo_test,
        [self(), {secured, ClientSwarm}]
    ),

    gen_server:stop(ClientStream0),

    Keys = libp2p_framed_stream:mk_secured_keypair(ClientSwarm),
    {ok, ClientStream} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        libp2p_swarm:p2p_address(ServerSwarm),
        Version,
        libp2p_secure_framed_stream_echo_test,
        [self(), {secured, ClientSwarm}, {keys, Keys}]
    ),

    lists:foreach(
        fun(_) ->
            Data = crypto:strong_rand_bytes(16),
            ClientStream ! {send, Data},
            receive
                {echo, server, Data} -> ok;
                _Else -> ct:fail(_Else)
            after 250 ->
                ct:fail(timeout)
            end
        end,
        lists:seq(1, 100)
    ),

    ?assert(erlang:is_process_alive(ClientStream)),

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ClientSwarm),
    ok.


failed_stream(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]},{libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}],
    Version = "securetest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(secure_server_fail_qecho_test, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_secure_framed_stream_echo_test, self(), {secured, ServerSwarm}]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(secure_client_fail_echo_test, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),

    [ServerAddress|_] = libp2p_swarm:listen_addrs(ServerSwarm),

    % Dialing here to propagate peerbook
    {ok, ClientStream0} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        ServerAddress,
        Version,
        libp2p_secure_framed_stream_echo_test,
        [self()]
    ),
    timer:sleep(2000),
    gen_server:stop(ClientStream0),

    {ok, ClientStream} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        libp2p_swarm:p2p_address(ServerSwarm),
        Version,
        libp2p_secure_framed_stream_echo_test,
        [self()]
    ),

    Data = crypto:strong_rand_bytes(16),
    ClientStream ! {send, Data},
    ok = test_util:wait_until(fun() -> false =:= erlang:is_process_alive(ClientStream) end),

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ClientSwarm),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
