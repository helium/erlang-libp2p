-module(proxy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0
    ,init_per_testcase/2
    ,end_per_testcase/2
]).

-export([
    basic/1
    ,two_proxy/1
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
    [basic, two_proxy].

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
    Version = "proxytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(a_proxy, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ASwarm]}
    ),

    {ok, RSwarm} = libp2p_swarm:start(r_proxy, SwarmOpts ++ [{proxy, [{address, "localhost"}, {port, 8080}]}]),
    ok = libp2p_swarm:listen(RSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), RSwarm]}
    ),

    {ok, BSwarm} = libp2p_swarm:start(b_proxy, SwarmOpts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), BSwarm]}
    ),

    [RAddress|_] = libp2p_swarm:listen_addrs(RSwarm),

    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ASwarm, RAddress, []),
    % Waiting for connection
    timer:sleep(2000),

    % NAT fails so B dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(BSwarm, RAddress, []),
    % Waiting for connection
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() ->
                                      [] /= get_relay_addresses(ASwarm)
                              end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ARelayAddress] = get_relay_addresses(ASwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(BSwarm), libp2p_swarm:address(ASwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ARelayAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    % B dials A via the relay address (so dialing R realy)
    {ok, Client} = libp2p_swarm:dial_framed_stream(
        BSwarm
        ,ARelayAddress
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    timer:sleep(2000),

    Data = <<"some data">>,
    Client ! Data,
    receive
        {echo, Data} -> ok
    after 5000 ->
        ct:fail(timeout)
    end,

    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(RSwarm),
    ok = libp2p_swarm:stop(BSwarm),

    timer:sleep(2000),
    ok.

two_proxy(_Config) ->
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
    Version = "proxytest/1.0.0",

    {ok, ASwarm} = libp2p_swarm:start(a_proxy, SwarmOpts),
    ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ASwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ASwarm]}
    ),

    {ok, RSwarm} = libp2p_swarm:start(r_proxy, SwarmOpts ++ [{proxy, [{address, "localhost"}, {port, 8080}]}]),
    ok = libp2p_swarm:listen(RSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        RSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), RSwarm]}
    ),

    {ok, BSwarm} = libp2p_swarm:start(b_proxy, SwarmOpts),
    ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        BSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), BSwarm]}
    ),

    {ok, CSwarm} = libp2p_swarm:start(c_proxy, SwarmOpts),
    ok = libp2p_swarm:listen(CSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        CSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), CSwarm]}
    ),

    [RAddress|_] = libp2p_swarm:listen_addrs(RSwarm),

    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ASwarm, RAddress, []),

    % NAT fails so B dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(BSwarm, RAddress, []),

    % NAT fails so C dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(CSwarm, RAddress, []),

    % Waiting for connection
    timer:sleep(2000),

    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ASwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ARelayAddress] = get_relay_addresses(ASwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(BSwarm), libp2p_swarm:address(ASwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ARelayAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    %% wait for C to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(CSwarm), libp2p_swarm:address(ASwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ARelayAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    % B dials A via the relay address (so dialing R realy)
    {ok, Client} = libp2p_swarm:dial_framed_stream(
        BSwarm
        ,ARelayAddress
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    % C dials A via the relay address (so dialing R realy)
    {ok, Client2} = libp2p_swarm:dial_framed_stream(
        CSwarm
        ,ARelayAddress
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    timer:sleep(2000),

    Data = <<"some data">>,
    Client ! Data,
    receive
        {echo, Data} -> ok
    after 5000 ->
        ct:fail(timeout_a)
    end,

    Data2 = <<"some other data">>,
    Client2 ! Data2,
    receive
        {echo, Data2} -> ok
    after 5000 ->
        ct:fail(timeout_c)
    end,

    ok = libp2p_swarm:stop(ASwarm),
    ok = libp2p_swarm:stop(RSwarm),
    ok = libp2p_swarm:stop(BSwarm),
    ok = libp2p_swarm:stop(CSwarm),

    timer:sleep(2000),
    ok.



%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_relay_addresses(pid()) -> [string()].
get_relay_addresses(Swarm) ->
    SwarmAddresses = libp2p_swarm:listen_addrs(Swarm),
    lists:filter(
        fun(Addr) ->
            case multiaddr:protocols(multiaddr:new(Addr)) of
                [{"p2p", _}, {"p2p-circuit", _}] ->
                    true;
                _ ->
                    false
            end
        end
        ,SwarmAddresses
    ).
