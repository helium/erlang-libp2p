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
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
    Version = "relaytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(basic_a, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ASwarm]}
    ),

    {ok, RSwarm} = libp2p_swarm:start(basic_r, SwarmOpts),
    ok = libp2p_swarm:listen(RSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), RSwarm]}
    ),

    {ok, BSwarm} = libp2p_swarm:start(basic_b, SwarmOpts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), BSwarm]}
    ),

    [RAddress|_] = libp2p_swarm:listen_addrs(RSwarm),
    % B connect to R for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        BSwarm
        ,RAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ASwarm, RAddress, []),

    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ASwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ARelayAddress] = get_relay_addresses(ASwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(BSwarm), libp2p_swarm:address(ASwarm)) of
                {ok, PeerBookEntry} ->
                    lists:member(ARelayAddress, libp2p_peer:listen_addrs(PeerBookEntry));
                _ ->
                    false
            end
        end
        ,40
        ,250
    ),

    % B dials A via the relay address (so dialing R realy)
    {ok, _} = libp2p_swarm:dial_framed_stream(
        BSwarm
        ,ARelayAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),

    timer:sleep(2000),
    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(RSwarm),
    ok = libp2p_swarm:stop(BSwarm),

    timer:sleep(2000),
    ok.

init_failed(_Config) ->
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
    {ok, Swarm} = libp2p_swarm:start(init_failed, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

    {error, no_peer} = libp2p_relay:init(Swarm),

    ok = libp2p_swarm:stop(Swarm),

    timer:sleep(2000),
    ok.

init_success(_Config) ->
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
    Version = "relaytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(init_success_a, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ASwarm]}
    ),

    {ok, BSwarm} = libp2p_swarm:start(init_success_b, SwarmOpts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), BSwarm]}
    ),

    [BAddress|_] = libp2p_swarm:listen_addrs(BSwarm),
    {ok, _} = libp2p_swarm:dial_framed_stream(
        ASwarm
        ,BAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    timer:sleep(2000),

    {ok, _} = libp2p_relay:init(ASwarm),
    timer:sleep(2000),

    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(BSwarm),

    timer:sleep(2000),
    ok.


dead_peer(_Config) ->
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
    Version = "relaytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(dead_peer_a, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ASwarm]}
    ),

    {ok, RSwarm} = libp2p_swarm:start(dead_peer_r, SwarmOpts),
    ok = libp2p_swarm:listen(RSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), RSwarm]}
    ),

    {ok, BSwarm} = libp2p_swarm:start(dead_peer_b, SwarmOpts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), BSwarm]}
    ),

    [RAddress|_] = libp2p_swarm:listen_addrs(RSwarm),
    % B connect to R for PeerBook gossip
    {ok, _} = libp2p_swarm:dial_framed_stream(
        BSwarm
        ,RAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),
    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ASwarm, RAddress, []),
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ASwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ARelayAddress] = get_relay_addresses(ASwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(
        fun() ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(BSwarm), libp2p_swarm:address(ASwarm)) of
                {ok, PeerBookEntry} ->
                    lists:member(ARelayAddress, libp2p_peer:listen_addrs(PeerBookEntry));
                _ ->
                    false
            end
        end
        ,40
        ,250
    ),

    %% stop the A swarm
    ok = libp2p_swarm:stop(ASwarm),
    timer:sleep(2000),

    % B dials A via the relay address (so dialing R realy)
    {error, "a_down"} = libp2p_swarm:dial_framed_stream(
        BSwarm
        ,ARelayAddress
        ,Version
        ,libp2p_stream_relay_test
        ,[]
    ),

    timer:sleep(2000),
    ok = libp2p_swarm:stop(RSwarm),
    ok = libp2p_swarm:stop(BSwarm),

    timer:sleep(2000),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

get_relay_addresses(Swarm) ->
    SwarmAddresses = libp2p_swarm:listen_addrs(Swarm),
    lists:filter(
        fun(Addr) ->
            case multiaddr:protocols(multiaddr:new(Addr)) of
                [{"p2p", _}, {"p2p-circuit", _}] -> true;
                _ -> false
            end
        end
        ,SwarmAddresses
    ).
