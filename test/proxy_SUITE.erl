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
    two_proxy/1,
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
    [basic, two_proxy, limit_exceeded].

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
    SwarmOpts = [{libp2p_nat, [{enabled, false}]},
                 {libp2p_group_gossip, [{peer_cache_timeout, 100}]}
                ],
    Version = "proxytest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(proxy_basic_server, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ServerSwarm]}
    ),

    Opts = SwarmOpts ++ [{libp2p_proxy, [{address, "localhost"}, {port, 18080}]}],
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
        case libp2p_peerbook:get(libp2p_swarm:peerbook(ClientSwarm), libp2p_swarm:pubkey_bin(ServerSwarm)) of
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

    %% 2 connections, each registered twice once as p2p and one as ipv4
    4 = length(libp2p_swarm:sessions(ProxySwarm)),

    %% really close the socket here
    {ok, Session} = libp2p_connection:session(libp2p_framed_stream:connection(ClientStream)),
    libp2p_framed_stream:close(ClientStream),
    libp2p_session:close(Session),

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ClientSwarm),


    %% check we didn't leak any sockets here
    ok = test_util:wait_until(fun() ->
                                      [{_ID, Info}] = ranch:info(),
                                      0 == proplists:get_value(active_connections, Info) andalso
                                      0 == proplists:get_value(all_connections, Info)
                              end),

    ok = libp2p_swarm:stop(ProxySwarm),

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

    Opts = SwarmOpts ++ [{libp2p_proxy, [{address, "localhost"}, {port, 18080}]}],
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
        case libp2p_peerbook:get(libp2p_swarm:peerbook(Client1Swarm), libp2p_swarm:pubkey_bin(ServerSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    %% wait for C to get A's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(Client2Swarm), libp2p_swarm:pubkey_bin(ServerSwarm)) of
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

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
limit_exceeded(_Config) ->
    SwarmOpts = [
        {libp2p_nat, [{enabled, false}]},
        {libp2p_group_gossip, [{peer_cache_timeout, 100}]},
        {libp2p_proxy, [{limit, 1}]}
    ],
    Version = "proxytest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(proxy_limit_exceeded_server, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ServerSwarm]}
    ),

    Opts = SwarmOpts ++ [{libp2p_proxy, [{address, "localhost"}, {port, 18080}]}],
    {ok, ProxySwarm} = libp2p_swarm:start(proxy_limit_exceeded_proxy, Opts),
    ok = libp2p_swarm:listen(ProxySwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ProxySwarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ProxySwarm]}
    ),

    {ok, ClientSwarm1} = libp2p_swarm:start(proxy_limit_exceeded_client1, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm1, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ClientSwarm1
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), ClientSwarm1]}
    ),

    {ok, ClientSwarm2} = libp2p_swarm:start(proxy_limit_exceeded_client2, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm2, "/ip4/0.0.0.0/tcp/0"),

    [ProxyAddress|_] = libp2p_swarm:listen_addrs(ProxySwarm),

    % NAT fails so Server dials Proxy to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ServerSwarm, ProxyAddress, []),
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ServerSwarm) end),

    % NAT fails so Client1 dials Proxy to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ClientSwarm1, ProxyAddress, []),
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ClientSwarm1) end),

    % NAT fails so Client2 dials Proxy to create a relay
    {ok, _} = libp2p_relay:dial_framed_stream(ClientSwarm2, ProxyAddress, []),
    ok = test_util:wait_until(fun() -> [] /= get_relay_addresses(ClientSwarm2) end),

    % Testing relay address
    % Once relay is established get relay address from A's peerbook
    [ServerCircuitAddress] = get_relay_addresses(ServerSwarm),

    %% wait for Server to get Client1's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(ClientSwarm1), libp2p_swarm:pubkey_bin(ServerSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    %% wait for Server to get Client1's relay address gossiped to it
    ok = test_util:wait_until(fun() ->
        case libp2p_peerbook:get(libp2p_swarm:peerbook(ClientSwarm2), libp2p_swarm:pubkey_bin(ServerSwarm)) of
            {ok, PeerBookEntry} ->
                lists:member(ServerCircuitAddress, libp2p_peer:listen_addrs(PeerBookEntry));
            _ ->
                false
        end
    end),

    % Client1 dials Server via the relay address
    {ok, ClientStream1} = libp2p_swarm:dial_framed_stream(
        ClientSwarm1,
        ServerCircuitAddress,
        Version,
        libp2p_stream_proxy_test,
        [{echo, self()}]
    ),
    timer:sleep(2000),

    Data = <<"some data">>,
    ClientStream1 ! Data,
    receive
        {echo, Data} -> ok
    after 5000 ->
        ct:fail(timeout)
    end,

    %% 2 connections, each registered twice once as p2p and one as ipv4
    ?assertEqual(6, length(libp2p_swarm:sessions(ProxySwarm))),

    % Avoid trying another address
    meck:new(libp2p_peer, [no_link, passthrough]),
    meck:expect(libp2p_peer, listen_addrs, fun(_) -> [] end),

    timer:sleep(2000),

    {error, _} = libp2p_swarm :dial_framed_stream(
        ClientSwarm2,
        ServerCircuitAddress,
        Version,
        libp2p_stream_proxy_test,
        [{echo, self()}]
    ),


    %% really close the socket here
    {ok, Session} = libp2p_connection:session(libp2p_framed_stream:connection(ClientStream1)),
    libp2p_framed_stream:close(ClientStream1),
    libp2p_session:close(Session),

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ClientSwarm1),
    ok = libp2p_swarm:stop(ClientSwarm2),

    %% check we didn't leak any sockets here
    ok = test_util:wait_until(fun() ->
                                      [{_ID, Info}] = ranch:info(),
                                      0 == proplists:get_value(active_connections, Info) andalso
                                      0 == proplists:get_value(all_connections, Info)
                              end),

    ok = libp2p_swarm:stop(ProxySwarm),

    timer:sleep(2000),
    ?assert(meck:validate(libp2p_peer)),
    meck:unload(libp2p_peer),
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
