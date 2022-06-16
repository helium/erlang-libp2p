-module(relay_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic/1
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
    [basic].

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
    SwarmOpts = [
        {libp2p_nat, [{enabled, false}]},
        {libp2p_peerbook, [{force_network_id, <<"GossipTestSuite">>}]}
    ],
    Version = "relaytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(relay_basic_a, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ASwarm]}
    ),

    {ok, BSwarm} = libp2p_swarm:start(relay_basic_b, SwarmOpts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), BSwarm]}
    ),

    {ok, CSwarm} = libp2p_swarm:start(relay_basic_c, SwarmOpts),
    ok = libp2p_swarm:listen(CSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        CSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), CSwarm]}
    ),

    % Relay needs a public ip now, not just a circuit address
    meck:new(libp2p_transport_tcp, [no_link, passthrough]),
    meck:expect(libp2p_transport_tcp, is_public, fun(_) -> true end),

    ct:pal("A swarm ~p", [libp2p_swarm:p2p_address(ASwarm)]),
    ct:pal("B swarm ~p", [libp2p_swarm:p2p_address(BSwarm)]),
    ct:pal("C swarm ~p", [libp2p_swarm:p2p_address(CSwarm)]),

    [CAddress|_] = libp2p_swarm:listen_addrs(CSwarm),
    % A connect to C for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ASwarm,
        CAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),
    % B connect to C for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        BSwarm,
        CAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),

    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(BSwarm), libp2p_swarm:pubkey_bin(ASwarm)) of
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


    % Testing relay address
    [ACircuitAddress] = get_relay_addresses(ASwarm),
    ct:pal("ACircuitAddress ~p", [ACircuitAddress]),

    % wait for C to get A's relay address gossiped to it
    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(CSwarm), libp2p_swarm:pubkey_bin(ASwarm)) of
                {ok, PeerBookEntry} ->
                    lists:member(ACircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
                _ ->
                    false
            end
        end,
        100,
        250
    ),

    {ok, _} = libp2p_swarm:dial_framed_stream(
        CSwarm,
        ACircuitAddress,
        Version,
        libp2p_stream_relay_test,
        []
    ),

    ok = libp2p_swarm:stop(BSwarm),
    % wait for A to remove its relay address in C
    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(CSwarm), libp2p_swarm:pubkey_bin(ASwarm)) of
                {ok, PeerBookEntry} ->
                    not lists:member(ACircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
                _ ->
                    false
            end
        end,
        100,
        250
    ),

    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(CSwarm),
    ?assert(meck:validate(libp2p_transport_tcp)),
    meck:unload(libp2p_transport_tcp),
    ?assert(meck:validate(libp2p_relay)),
    meck:unload(libp2p_relay),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

get_relay_addresses(Swarm) ->
    SwarmAddresses = libp2p_swarm:listen_addrs(Swarm),
    lists:filter(
        fun(Addr) ->
            case multiaddr:protocols(Addr) of
                [{"p2p", _}, {"p2p-circuit", _}] -> true;
                _ -> false
            end
        end
        ,SwarmAddresses
    ).
