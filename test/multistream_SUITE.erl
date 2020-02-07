-module(multistream_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([client_ls_test/1, client_negotiate_handler_test/1]).

all() ->
    [
     client_ls_test
    , client_negotiate_handler_test
    ].

init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    [Swarm] = test_util:setup_swarms(1, [{base_dir, ?config(base_dir, Config0)}]),
    [Addr|_] = libp2p_swarm:listen_addrs(Swarm),

    [{"ip4", IPStr}, {"tcp", PortStr}] = multiaddr:protocols(Addr),
    {ok, IP} = inet:parse_address(IPStr),
    Port  =  list_to_integer(PortStr),
    {ok, Socket} = ranch_tcp:connect(IP, Port, [inet]),
    Connection = libp2p_transport_tcp:new_connection(Socket),

    [{swarm, Swarm}, {connection, Connection} | Config].

end_per_testcase(_, Config) ->
    Swarm = ?config(swarm, Config),
    test_util:teardown_swarms([Swarm]).

%% Tests
%%

client_ls_test(Config) ->
    Connection = ?config(connection, Config),

    ok = libp2p_multistream_client:handshake(Connection),
    true = lists:member("yamux/1.0.0", libp2p_multistream_client:ls(Connection)),
    ok =  libp2p_multistream_client:select("yamux/1.0.0", Connection),

    ok.

client_negotiate_handler_test(Config) ->
    Connection = ?config(connection, Config),

    Handlers = [{"othermux", "othermux"}, {"yamux/1.0.0", "yamux"}],
    {ok, "yamux"} = libp2p_multistream_client:negotiate_handler(Handlers, "", Connection),

    ok.
