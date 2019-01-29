-module(relay_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0
    ,init_per_testcase/2
    ,end_per_testcase/2
]).

-export([
    basic/1
    ,init_failed/1
    ,init_success/1
    ,dead_peer/1
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
    [basic, init_failed, init_success, dead_peer].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_, Config) ->
    test_util:setup(),
    lager:set_loglevel(lager_console_backend, info),
    Config.

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
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    Version = "relaytest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(relay_basic_server, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ServerSwarm]}
    ),

    {ok, RelaySwarm} = libp2p_swarm:start(relay_basic_relay, SwarmOpts),
    ok = libp2p_swarm:listen(RelaySwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RelaySwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), RelaySwarm]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(relay_basic_client, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ClientSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ClientSwarm]}
    ),

    [RelayAddress|_] = libp2p_swarm:listen_addrs(RelaySwarm),
    % B connect to R for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ClientSwarm
        ,RelayAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ServerSwarm, RelayAddress, []),

    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ServerSwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ServerCircuitAddress] = get_relay_addresses(ServerSwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(ClientSwarm), libp2p_swarm:pubkey_bin(ServerSwarm)) of
                {ok, PeerBookEntry} ->
                    lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
                _ ->
                    false
            end
        end
        ,40
        ,250
    ),

    % B dials A via the relay address (so dialing R realy)
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ClientSwarm
        ,ServerCircuitAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),

    timer:sleep(2000),
    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(RelaySwarm),
    ok = libp2p_swarm:stop(ClientSwarm),

    timer:sleep(2000),
    ok.

init_failed(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    {ok, Swarm} = libp2p_swarm:start(relay_init_failed, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

    {error, no_peer} = libp2p_relay:init(Swarm),

    ok = libp2p_swarm:stop(Swarm),

    timer:sleep(2000),
    ok.

init_success(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    Version = "relaytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(relay_init_success_server, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ASwarm]}
    ),

    {ok, RelaySwarm} = libp2p_swarm:start(relay_init_success_relay, SwarmOpts),
    ok = libp2p_swarm:listen(RelaySwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RelaySwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), RelaySwarm]}
    ),

    [RelayAddress|_] = libp2p_swarm:listen_addrs(RelaySwarm),
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ASwarm
        ,RelayAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    timer:sleep(2000),

    {ok, _} = libp2p_relay:init(ASwarm),
    timer:sleep(2000),

    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(RelaySwarm),

    timer:sleep(2000),
    ok.


dead_peer(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    Version = "relaytest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(relay_dead_peer_server, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ServerSwarm]}
    ),

    {ok, RelaySwarm} = libp2p_swarm:start(relay_dead_peer_relay, SwarmOpts),
    ok = libp2p_swarm:listen(RelaySwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RelaySwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), RelaySwarm]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(relay_dead_peer_client, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ClientSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ClientSwarm]}
    ),

    [RelayAddress|_] = libp2p_swarm:listen_addrs(RelaySwarm),
    % B connect to R for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ClientSwarm
        ,RelayAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ServerSwarm, RelayAddress, []),
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ServerSwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ServerCircuitAddress] = get_relay_addresses(ServerSwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(ClientSwarm), libp2p_swarm:pubkey_bin(ServerSwarm)) of
                {ok, PeerBookEntry} ->
                    lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
                _ ->
                    false
            end
        end
        ,40
        ,250
    ),

    %% stop the A swarm
    ok = libp2p_swarm:stop(ServerSwarm),
    timer:sleep(2000),

    % B dials A via the relay address (so dialing R realy)
    R = libp2p_swarm:dial_framed_stream(
        ClientSwarm
        ,ServerCircuitAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    ?assertEqual({error, "server_down"}, R),

    timer:sleep(2000),
    ok = libp2p_swarm:stop(RelaySwarm),
    ok = libp2p_swarm:stop(ClientSwarm),

    timer:sleep(2000),
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
