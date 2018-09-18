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
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    Version = "proxytest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(proxy_basic_server, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ServerSwarm]}
    ),

    Opts = SwarmOpts ++ [{libp2p_proxy_server, [{address, "localhost"}, {port, 18080}]}],
    {ok, ProxySwarm} = libp2p_swarm:start(proxy_basic_proxy, Opts),
    ok = libp2p_swarm:listen(ProxySwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ProxySwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ProxySwarm]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(proxy_basic_client, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ClientSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ClientSwarm]}
    ),

    [ProxyAddress|_] = libp2p_swarm:listen_addrs(ProxySwarm),

    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ServerSwarm, ProxyAddress, []),
    % Waiting for connection
    timer:sleep(2000),

    % NAT fails so B dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ClientSwarm, ProxyAddress, []),
    % Waiting for connection
    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ServerSwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ServerCircuitAddress] = get_relay_addresses(ServerSwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(ClientSwarm), libp2p_swarm:address(ServerSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    % B dials A via the relay address (so dialing R realy)
    {ok, ClientStream} = libp2p_swarm:dial_framed_stream(
        ClientSwarm
        ,ServerCircuitAddress
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    timer:sleep(2000),

    Data = <<"some data">>,
    ClientStream ! Data,
    receive
        {echo, Data} -> ok
    after 5000 ->
        ct:fail(timeout)
    end,

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ProxySwarm),
    ok = libp2p_swarm:stop(ClientSwarm),

    timer:sleep(2000),
    ok.

two_proxy(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    Version = "proxytest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(proxy_two_server, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ServerSwarm]}
    ),

    Opts = SwarmOpts ++ [{libp2p_proxy_server, [{address, "localhost"}, {port, 18080}]}],
    {ok, ProxySwarm} = libp2p_swarm:start(proxy_two_proxy, Opts),
    ok = libp2p_swarm:listen(ProxySwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ProxySwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ProxySwarm]}
    ),

    {ok, Client1Swarm} = libp2p_swarm:start(proxy_two_client_1, SwarmOpts),
    ok = libp2p_swarm:listen(Client1Swarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        Client1Swarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), Client1Swarm]}
    ),

    {ok, Client2Swarm} = libp2p_swarm:start(proxy_two_client_2, SwarmOpts),
    ok = libp2p_swarm:listen(Client2Swarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        Client2Swarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), Client2Swarm]}
    ),

    [ProxyAddress|_] = libp2p_swarm:listen_addrs(ProxySwarm),

    % NAT fails so A dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ServerSwarm, ProxyAddress, []),

    % NAT fails so B dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(Client1Swarm, ProxyAddress, []),

    % NAT fails so C dials R to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(Client2Swarm, ProxyAddress, []),

    % Waiting for connection
    timer:sleep(2000),

    % Wait for a relay address to be provided
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ServerSwarm) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ServerCircuitAddress] = get_relay_addresses(ServerSwarm),

    %% wait for B to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(Client1Swarm), libp2p_swarm:address(ServerSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    %% wait for C to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(Client2Swarm), libp2p_swarm:address(ServerSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    % B dials A via the relay address (so dialing R realy)
    {ok, ClientStream1} = libp2p_swarm:dial_framed_stream(
        Client1Swarm
        ,ServerCircuitAddress
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    % C dials A via the relay address (so dialing R realy)
    {ok, ClientStream2} = libp2p_swarm:dial_framed_stream(
        Client2Swarm
        ,ServerCircuitAddress
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    timer:sleep(2000),

    Data = <<"some data">>,
    ClientStream1 ! Data,
    receive
        {echo, Data} -> ok
    after 5000 ->
        ct:fail(timeout_client1)
    end,

    Data2 = <<"some other data">>,
    ClientStream2 ! Data2,
    receive
        {echo, Data2} -> ok
    after 5000 ->
        ct:fail(timeout_client2)
    end,

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ProxySwarm),
    ok = libp2p_swarm:stop(Client1Swarm),
    ok = libp2p_swarm:stop(Client2Swarm),

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
            case multiaddr:protocols(Addr) of
                [{"p2p", _}, {"p2p-circuit", _}] ->
                    true;
                _ ->
                    false
            end
        end
        ,SwarmAddresses
    ).
