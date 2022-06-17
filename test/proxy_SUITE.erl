-module(proxy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic/1,
    limit_exceeded/1
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
    [basic, limit_exceeded].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    test_util:setup(),
    lager:set_loglevel(lager_console_backend, info),
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
basic(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]},
                 {libp2p_group_gossip, [{peer_cache_timeout, 100}]},
                 {libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}
                ],
    Version = "proxytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(proxy_basic_server, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ASwarm]}
    ),

    Opts = SwarmOpts ++ [{libp2p_proxy, [{address, "localhost"}, {port, 18080}]}],
    {ok, BSwarm} = libp2p_swarm:start(proxy_basic_proxy, Opts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), BSwarm]}
    ),

    {ok, CSwarm} = libp2p_swarm:start(proxy_basic_client, SwarmOpts),
    ok = libp2p_swarm:listen(CSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        CSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), CSwarm]}
    ),

    % Relay needs a public ip now, not just a circuit address
    meck:new(libp2p_transport_tcp, [no_link, passthrough]),
    meck:expect(libp2p_transport_tcp, is_public, fun(_) -> false end),
    meck:new(libp2p_peer, [no_link, passthrough]),
    meck:expect(libp2p_peer, has_public_ip, fun(_) -> true end),


    ct:pal("ASwarm ~p", [libp2p_swarm:p2p_address(ASwarm)]),
    ct:pal("BSwarm ~p", [libp2p_swarm:p2p_address(BSwarm)]),
    ct:pal("CSwarm ~p", [libp2p_swarm:p2p_address(CSwarm)]),

    [BAddress|_] = libp2p_swarm:listen_addrs(BSwarm),

    {ok, _} = libp2p_swarm:dial_framed_stream(
        CSwarm,
        BAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ASwarm,
        BAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),

    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(CSwarm), libp2p_swarm:pubkey_bin(ASwarm)) of
                {ok, _} -> true;
                _ -> false
            end
        end,
        100,
        250
    ),

    BP2P = libp2p_swarm:p2p_address(BSwarm),
    meck:new(libp2p_relay, [no_link, passthrough]),
    meck:expect(libp2p_relay, dial_framed_stream,
        fun(S, _A, []) ->
            meck:passthrough([S, BP2P, []]);
        (S, A, O) ->
            meck:passthrough([S, A, O])
        end
    ),

    try

    % NAT fails so init relay on A manually
    ok = libp2p_relay:init(ASwarm),
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ASwarm) end),

    % NAT fails so init relay on C manually
    ok = libp2p_relay:init(CSwarm),
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(CSwarm) end),


    [CCircuitAddress] = get_relay_addresses(CSwarm),
    [ACircuitAddress] = get_relay_addresses(ASwarm),
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(ASwarm), libp2p_swarm:pubkey_bin(CSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(CCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end, 60, 500),
    ct:pal("CCircuitAddress ~p", [CCircuitAddress]),
    ct:pal("ACircuitAddress ~p", [ACircuitAddress]),

    {ok, ClientStream} = libp2p_swarm:dial_framed_stream(
        ASwarm,
        CCircuitAddress,
        Version,
        libp2p_stream_proxy_test,
        [{echo, self()}]
    ),
    timer:sleep(2000),

    Data = <<"some data">>,
    ClientStream ! Data,
    receive
        {echo, Data} -> ok
    after 5000 ->
        ct:fail(timeout)
    end,

    %% 2 connections, each registered twice once as p2p and one as ipv4
    4 = length(libp2p_swarm:sessions(BSwarm)),

    %% really close the socket here
    {ok, Session} = libp2p_connection:session(libp2p_framed_stream:connection(ClientStream)),
    libp2p_framed_stream:close(ClientStream),
    libp2p_session:close(Session)

    after

    ok = libp2p_swarm:stop(CSwarm),
    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(BSwarm)

    end,

    %% check we didn't leak any sockets here
    ok = check_sockets(),
    timer:sleep(2000),
    ?assert(meck:validate(libp2p_relay)),
    meck:unload(libp2p_relay),
    ?assert(meck:validate(libp2p_transport_tcp)),
    meck:unload(libp2p_transport_tcp),
    ?assert(meck:validate(libp2p_peer)),
    meck:unload(libp2p_peer),
    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
limit_exceeded(_Config) ->
    SwarmOpts = [
        {libp2p_nat, [{enabled, false}]},
        {libp2p_group_gossip, [{peer_cache_timeout, 100}]},
        {libp2p_proxy, [{limit, 0}]},
        {libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}
    ],
    Version = "proxytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(proxy_limit_exceeded_server, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ASwarm]}
    ),

    Opts = SwarmOpts ++ [{libp2p_proxy, [{address, "localhost"}, {port, 18080}]}],
    {ok, BSwarm} = libp2p_swarm:start(proxy_limit_exceeded_proxy, Opts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), BSwarm]}
    ),

    {ok, CSwarm} = libp2p_swarm:start(proxy_limit_exceeded_client, SwarmOpts),
    ok = libp2p_swarm:listen(CSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        CSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), CSwarm]}
    ),

    %% Relay needs a public ip now, not just a circuit address
    meck:new(libp2p_transport_tcp, [no_link, passthrough]),
    meck:expect(libp2p_transport_tcp, is_public, fun(_) -> false end),
    meck:new(libp2p_peer, [no_link, passthrough]),
    meck:expect(libp2p_peer, has_public_ip, fun(_) -> true end),

    ct:pal("ASwarm ~p", [libp2p_swarm:p2p_address(ASwarm)]),
    ct:pal("BSwarm ~p", [libp2p_swarm:p2p_address(BSwarm)]),
    ct:pal("CSwarm ~p", [libp2p_swarm:p2p_address(CSwarm)]),

    try

    [ProxyAddress|_] = libp2p_swarm:listen_addrs(BSwarm),

    {ok, _} = libp2p_swarm:dial_framed_stream(
        CSwarm,
        ProxyAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),
    % B connect to C for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ASwarm,
        ProxyAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),

    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(CSwarm), libp2p_swarm:pubkey_bin(ASwarm)) of
                {ok, _} -> true;
                _ -> false
            end
        end,
        200,
        250
    ),

    % Force B to be the relay
    BP2P = libp2p_swarm:p2p_address(BSwarm),
    meck:new(libp2p_relay, [no_link, passthrough]),
    meck:expect(libp2p_relay, dial_framed_stream,
        fun(S, _A, []) ->
            meck:passthrough([S, BP2P, []]);
        (S, A, O) ->
            meck:passthrough([S, A, O])
        end
    ),

    % NAT fails so init relay on A manually
    ok = libp2p_relay:init(ASwarm),
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ASwarm) end),

    % NAT fails so init relay on C manually
    ok = libp2p_relay:init(CSwarm),
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(CSwarm) end),


    [CCircuitAddress] = get_relay_addresses(CSwarm),
    [ACircuitAddress] = get_relay_addresses(ASwarm),
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(ASwarm), libp2p_swarm:pubkey_bin(CSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(CCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end, 200, 200),
    ct:pal("CCircuitAddress ~p", [CCircuitAddress]),
    ct:pal("ACircuitAddress ~p", [ACircuitAddress]),
    % Avoid trying another address
    meck:expect(libp2p_peer, listen_addrs, fun(_) -> [] end),

    % Client1 dials Server via the relay address
    {error, _} = libp2p_swarm:dial_framed_stream(
        CSwarm,
        ACircuitAddress,
        Version,
        libp2p_stream_proxy_test,
        [{echo, self()}]
    )

    after

    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(CSwarm),
    ok = libp2p_swarm:stop(BSwarm)

    end,

    %% check we didn't leak any sockets here
    ok = check_sockets(),
    timer:sleep(2000),
    ?assert(meck:validate(libp2p_relay)),
    meck:unload(libp2p_relay),
    ?assert(meck:validate(libp2p_transport_tcp)),
    meck:unload(libp2p_transport_tcp),
    ?assert(meck:validate(libp2p_peer)),
    meck:unload(libp2p_peer),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

check_sockets() ->
    test_util:wait_until(
        fun() ->
            lists:foldl(
                fun({_ID, _Info}, false) ->
                    false;
                ({_ID, Info}, _Acc) ->
                    ct:pal("Info ~p", [Info]),
                    0 == proplists:get_value(active_connections, Info) andalso
                    0 == proplists:get_value(all_connections, Info)
                end,
                true,
                ranch:info()
            )
        end,
        100,
        250
    ).

-spec get_relay_addresses(pid()) -> [string()].
get_relay_addresses(Swarm) ->
    SwarmAddresses = libp2p_swarm:listen_addrs(Swarm),
    lists:filter(
        fun(Addr) ->
            case multiaddr:protocols(Addr) of
                [{"p2p", _}, {"p2p-circuit", _}] ->
                    true;
                _ ->
                    false
            end
        end
        ,SwarmAddresses
    ).
