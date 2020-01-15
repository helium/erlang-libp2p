-module(listen_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    port0/1,
    addr0/1,
    already/1,
    bad_addr/1,
    port0_reuse/1,
    restart_transport/1,
    sort_addresses/1
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
    [port0, addr0, already, bad_addr, port0_reuse, restart_transport, sort_addresses].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    test_util:setup(),
    {ok, Swarm} = libp2p_swarm:start(test),
    [{swarm, Swarm} | Config0].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, Config) ->
    Swarm = ?config(swarm, Config),
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
    Swarm = ?config(swarm, Config),

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
    Swarm = ?config(swarm, Config),

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
    Swarm = ?config(swarm, Config),

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
    Swarm = ?config(swarm, Config),

    {error, {unsupported_address, _}} = libp2p_swarm:listen(Swarm, "/onion/timaq4ygg2iegci7:1234"),
    {error, {unsupported_address, _}} = libp2p_swarm:listen(Swarm, "/udp/1234/udt"),

    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
port0_reuse(_Config) ->
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],

    {ok, Swarm} = libp2p_swarm:start(listen_port0_reuse, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
    ok = libp2p_swarm:listen(Swarm, "/ip6/::/tcp/0"),

    ListenAddrs = libp2p_swarm:listen_addrs(Swarm),

    ok = libp2p_swarm:stop(Swarm),
    ok = test_util:wait_until(fun() -> true /= erlang:is_process_alive(Swarm) end),

    {ok, Swarm2} = libp2p_swarm:start(listen_port0_reuse, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm2, "/ip4/0.0.0.0/tcp/0"),
    ok = libp2p_swarm:listen(Swarm2, "/ip6/::/tcp/0"),

    ListenAddrs = libp2p_swarm:listen_addrs(Swarm2),
    ok = libp2p_swarm:stop(Swarm2),

    ok = test_util:wait_until(fun() -> true /= erlang:is_process_alive(Swarm2)  end),

    {ok, Swarm3} = libp2p_swarm:start(listen_port0_reuse2, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm3, "/ip4/127.0.0.1/tcp/0"),
    ok = libp2p_swarm:listen(Swarm3, "/ip6/::1/tcp/0"),

    ListenAddrs2 = libp2p_swarm:listen_addrs(Swarm3),

    ok = libp2p_swarm:stop(Swarm3),
    ok = test_util:wait_until(fun() -> true /= erlang:is_process_alive(Swarm3)  end),

    {ok, Swarm4} = libp2p_swarm:start(listen_port0_reuse2, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm4, "/ip4/127.0.0.1/tcp/0"),
    ok = libp2p_swarm:listen(Swarm4, "/ip6/::1/tcp/0"),

    ListenAddrs2 = libp2p_swarm:listen_addrs(Swarm4),
    ok = libp2p_swarm:stop(Swarm4),
    ok.

restart_transport(Config) ->
    Swarm = ?config(swarm, Config),

    [] = libp2p_swarm:listen_addrs(Swarm),
    ok = libp2p_swarm:listen(Swarm, "/ip4/127.0.0.1/tcp/0"),

    ["/ip4/127.0.0.1/" ++ _] = libp2p_swarm:listen_addrs(Swarm),

    {ok, Pid} = libp2p_config:lookup_transport(libp2p_swarm:tid(Swarm), libp2p_transport_tcp),
    exit(Pid, kill),
    ok = test_util:wait_until(fun() -> true /= erlang:is_process_alive(Pid) end),
    ok = test_util:wait_until(fun() ->
                                      case libp2p_config:lookup_transport(libp2p_swarm:tid(Swarm), libp2p_transport_tcp) of
                                          {ok, Pid} ->
                                              ct:pal("stale pid"),
                                              false;
                                          false ->
                                              ct:pal("no pid"),
                                              false;
                                          {ok, _} -> true
                                      end
                              end),
    {ok, Pid2} = libp2p_config:lookup_transport(libp2p_swarm:tid(Swarm), libp2p_transport_tcp),
    false = (Pid == Pid2),

    ok.

sort_addresses(Config) ->
    Swarm = ?config(swarm, Config),
    TID = libp2p_swarm:tid(Swarm),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
    Addresses = [
        "/ip4/10.0.0.2/tcp/51006",
        "/ip4/172.16.0.2/tcp/51006",
        "/ip4/192.168.0.2/tcp/51006",
        "/ip4/8.8.8.8/tcp/51006",
        "/ip4/4.4.4.4/tcp/51006",
        "/p2p/114FX56Ua6joFNmHAugjKR1wfopRyYEzbtgn6bodvSHXdKSwZPg/p2p-circuit/p2p/112kQbfzXkyxTSTxUpztvPLMJLB2koLro9LJesumSGpdNUBhWzBN",
        "/p2p/112kQbfzXkyxTSTxUpztvPLMJLB2koLro9LJesumSGpdNUBhWzBN"
    ],
    Sorted = libp2p_transport:sort_addrs(TID, Addresses),
    Expected = [
        "/ip4/4.4.4.4/tcp/51006",
        "/ip4/8.8.8.8/tcp/51006",
        "/p2p/114FX56Ua6joFNmHAugjKR1wfopRyYEzbtgn6bodvSHXdKSwZPg/p2p-circuit/p2p/112kQbfzXkyxTSTxUpztvPLMJLB2koLro9LJesumSGpdNUBhWzBN",
        "/p2p/112kQbfzXkyxTSTxUpztvPLMJLB2koLro9LJesumSGpdNUBhWzBN",
        "/ip4/10.0.0.2/tcp/51006",
        "/ip4/172.16.0.2/tcp/51006",
        "/ip4/192.168.0.2/tcp/51006"
    ],
    ?assertEqual(Expected, Sorted),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
