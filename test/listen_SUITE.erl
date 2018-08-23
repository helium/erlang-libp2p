-module(listen_SUITE).

-export([
    all/0
    ,init_per_testcase/2
    ,end_per_testcase/2
]).

-export([
    port0/1
    ,addr0/1
    ,already/1
    ,bad_addr/1
    ,port0_reuse/1
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
    [port0, addr0, already, bad_addr].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_, Config) ->
    test_util:setup(),
    {ok, Swarm} = libp2p_swarm:start(test),
    [{swarm, Swarm} | Config].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, Config) ->
    Swarm = proplists:get_value(swarm, Config),
    test_util:teardown_swarms([Swarm]).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
port0(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    [] = libp2p_swarm:listen_addrs(Swarm),
    ok = libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0"),

    ["/ip4/127.0.0.1/" ++ _] = libp2p_swarm:listen_addrs(Swarm),

    ok = libp2p_swarm:listen(Swarm, "/ip6/::1/tcp/0"),
    ["/ip4/127.0.0.1/" ++ _, "/ip6/::1/" ++ _] = libp2p_swarm:listen_addrs(Swarm),

    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
addr0(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    ok =  libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

    ListenAddrs = libp2p_swarm:listen_addrs(Swarm),
    true = length(ListenAddrs) > 0,

    PAddrs = lists:map(fun(N) -> multiaddr:protocols(N) end, ListenAddrs),
    lists:foreach(fun([{"ip4", IP},{"tcp", Port}]) ->
                          {ok, _} = inet:parse_ipv4_address(IP),
                          true = list_to_integer(Port) > 0
                  end, PAddrs),
    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
already(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    ok = libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0"),
    [ListenAddr] = libp2p_swarm:listen_addrs(Swarm),

    {error, _} = libp2p_swarm:listen(Swarm, ListenAddr),

    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
bad_addr(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    {error, {unsupported_address, _}} = libp2p_swarm:listen(Swarm, "/onion/timaq4ygg2iegci7:1234"),
    {error, {unsupported_address, _}} = libp2p_swarm:listen(Swarm, "/udp/1234/udt"),

    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
port0_reuse(_Config) ->
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],

    {ok, Swarm} = libp2p_swarm:start(listen_port0_reuse, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
    ok = libp2p_swarm:listen(Swarm, "/ip6/::/tcp/0"),

    timer:sleep(2000),
    ListenAddrs = libp2p_swarm:listen_addrs(Swarm),

    ok = libp2p_swarm:stop(Swarm),
    timer:sleep(2000),

    {ok, Swarm2} = libp2p_swarm:start(listen_port0_reuse, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm2, "/ip4/0.0.0.0/tcp/0"),
    ok = libp2p_swarm:listen(Swarm2, "/ip6/::/tcp/0"),

    timer:sleep(2000),
    ListenAddrs = libp2p_swarm:listen_addrs(Swarm2),
    ok = libp2p_swarm:stop(Swarm2),

    timer:sleep(2000),

    {ok, Swarm3} = libp2p_swarm:start(listen_port0_reuse2, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm3, "/ip4/127.0.0.1/tcp/0"),
    ok = libp2p_swarm:listen(Swarm3, "/ip6/::1/tcp/0"),

    timer:sleep(2000),
    ListenAddrs2 = libp2p_swarm:listen_addrs(Swarm3),

    ok = libp2p_swarm:stop(Swarm3),
    timer:sleep(2000),

    {ok, Swarm4} = libp2p_swarm:start(listen_port0_reuse2, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm4, "/ip4/127.0.0.1/tcp/0"),
    ok = libp2p_swarm:listen(Swarm4, "/ip6/::1/tcp/0"),

    timer:sleep(2000),
    ListenAddrs2 = libp2p_swarm:listen_addrs(Swarm4),
    ok = libp2p_swarm:stop(Swarm4),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

% ok() ->
% SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
% {ok, Swarm} = libp2p_swarm:start(port0_reuse, SwarmOpts),
% ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
% TID = libp2p_swarm:tid(Swarm),
% Sup = libp2p_swarm_listener_sup:sup(TID),
% observer:start().
%
%
% supervisor:terminate_child(Sup, {ranch_listener_sup,["/ip4/192.168.1.61/tcp/49880"]}).
%
%     Peerbook = libp2p_swarm:peerbook(Swarm),
%     ListenAddrs = [libp2p_peer:listen_addrs(Peer) || Peer <- libp2p_peerbook:values(Peerbook)],
%     [[Addr]] = ListenAddrs,
%     Split = string:split(Addr, "/", all),
%     _Port = lists:last(Split),
%
%
%     _ = libp2p_config:remove_listener(TID, Addr),
%
%     ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
