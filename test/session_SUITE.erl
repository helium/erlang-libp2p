-module(session_SUITE).


-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([open_close_test/1, ping_test/1]).

all() ->
    [
     open_close_test
     , ping_test
    ].

init_per_testcase(open_close_test, Config) ->
    Swarms = test_util:setup_swarms(2, [{libp2p_group_gossip,
                                         [{peerbook_connections, 0}]
                                        }]),
    [{swarms, Swarms} | Config];
init_per_testcase(ping_test, Config) ->
    Swarms = test_util:setup_swarms(2, []),
    [{swarms, Swarms} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

%% Tests
%%

open_close_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),

    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),
    {ok, Session1} = libp2p_swarm:connect(S1, S2Addr),
    open = libp2p_session:close_state(Session1),

    % open a reverse session
    {Session1Addr, _} = libp2p_session:addr_info(Session1),
    {ok, Session2} = libp2p_swarm:connect(S2, Session1Addr),

    % open another forward session, ensure session reuse
    {ok, Session1} = libp2p_swarm:connect(S1, S2Addr, [], 100),

    % and another one, but make it unique
    {ok, Session3} = libp2p_swarm:connect(S1, S2Addr, [{unique_session, true}], 100),
    false = Session1 == Session3,
    ok = libp2p_session:close(Session3),

    {ok, Stream1} = libp2p_session:open(Session1),
    true = libp2p_connection:addr_info(Stream1) == libp2p_session:addr_info(Session1),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session1)) == 1 end),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session2)) == 1 end),

    % Can write (up to a window size of) data without anyone on the
    % other side
    ok = libp2p_multistream_client:handshake(Stream1),

    % Close stream after sending some data on it
    ok = libp2p_connection:close(Stream1),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session1)) == 0 end),
    ok = test_util:wait_until(fun() -> length(libp2p_session:streams(Session2)) == 0 end),
    {error, closed} = libp2p_connection:send(Stream1, <<"hello">>),

    ok = libp2p_session:close(Session1),

    ok.

ping_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),

    [S2Addr|_] = libp2p_swarm:listen_addrs(S2),

    {ok, Session} = libp2p_swarm:connect(S1, S2Addr),
    {ok, _} = libp2p_session:ping(Session),

    ok.
