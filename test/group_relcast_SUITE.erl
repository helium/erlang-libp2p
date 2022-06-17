-module(group_relcast_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
         unicast_test/1,
         multicast_test/1,
         defer_test/1,
         close_test/1,
         restart_test/1,
         pipeline_test/1
        ]).

all() ->
    [ %% restart_test,
      unicast_test,
      multicast_test,
      defer_test,
      close_test %,
      %% todo fix this garbage thing at some point
      % pipeline_test
    ].

init_per_testcase(defer_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms(2, [{libp2p_peerbook, [{notify_time, 1000},
                                                           {force_network_id, <<"GossipTestSuite">>}]},
                                        {libp2p_group_gossip, [{peer_cache_timeout, 50}]},
                                        {libp2p_nat, [{enabled, false}]},
                                        {base_dir, ?config(base_dir, Config0)}]),
    [{swarms, Swarms} | Config];
init_per_testcase(close_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms(2, [{libp2p_peerbook, [{notify_time, 1000},
                                                           {force_network_id, <<"GossipTestSuite">>}]},
                                        {libp2p_group_gossip, [{peer_cache_timeout, 100}]},
                                        {libp2p_nat, [{enabled, false}]},
                                        {base_dir, ?config(base_dir, Config0)}]),
    [{swarms, Swarms} | Config];
init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms(3, [{libp2p_peerbook, [{notify_time, 1000},
                                                           {force_network_id, <<"GossipTestSuite">>}]},
                                        {libp2p_group_gossip, [{peer_cache_timeout, 100}]},
                                        {libp2p_nat, [{enabled, false}]},
                                        {base_dir, ?config(base_dir, Config0)}]),
    [{swarms, Swarms} | Config].

end_per_testcase(_, Config) ->
    Swarms = ?config(swarms, Config),
    test_util:teardown_swarms(Swarms).

unicast_test(Config) ->
    Swarms = [S1, S2, S3] = ?config(swarms, Config),

    ct:pal("self ~p", [self()]),

    test_util:connect_swarms(S1, S2),
    test_util:connect_swarms(S1, S3),
    test_util:connect_swarms(S2, S3),

    test_util:await_gossip_groups(Swarms),
    test_util:await_gossip_streams(Swarms),

    Members = [libp2p_swarm:pubkey_bin(S) || S <- Swarms],

    %% G1 takes input and unicasts it to itself, then handles the
    %% message to self by sending a message to G2
    G1Args = [relcast_handler, [Members, input_unicast(1), handle_msg([{unicast, 2, <<"unicast1">>}])], [{create, true}]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),
    %% Adding the same group twice is the same group pid
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles any incoming message by sending a message to member
    %% 3 (G3)
    G2Args = [relcast_handler, [Members, undefined, handle_msg([{unicast, 3, <<"unicast2">>}])], [{create, true}]],
    {ok, _G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    %% G3 handles a messages by just acknowledging it
    G3Args = [relcast_handler, [Members, undefined, handle_msg([])], [{create, true}]],
    {ok, _G3} = libp2p_swarm:add_group(S3, "test", libp2p_group_relcast, G3Args),

    %% Give G1 some input. This should end up getting to G2 who then
    %% sends a message to G3.
    libp2p_group_relcast:handle_input(G1, <<"unicast">>),

    %% Receive input message from G1 as handled by G1
    receive
        {handle_msg, 1, <<"unicast">>} -> ok
    after 15000 ->
              ct:pal("Messages: ~p", [erlang:process_info(self(), [messages])]),
              error(timeout)
    end,

    %% Receive message from G1 as handled by G2
    receive
        {handle_msg, 1, <<"unicast1">>} -> ok
    after 30000 ->
              ct:pal("Messages: ~p", [erlang:process_info(self(), [messages])]),
              error(timeout)
    end,

    %% Receive the message from G2 as handled by G3
    receive
        {handle_msg, 2, <<"unicast2">>} -> ok
    after 30000 ->
              ct:pal("Messages: ~p", [erlang:process_info(self(), [messages])]),
              error(timeout)
    end,
    ok.


multicast_test(Config) ->
    Swarms = [S1, S2, S3] = ?config(swarms, Config),

    test_util:connect_swarms(S1, S2),
    test_util:connect_swarms(S1, S3),
    test_util:connect_swarms(S2, S3),

    test_util:await_gossip_groups(Swarms),
    test_util:await_gossip_streams(Swarms),

    Members = [libp2p_swarm:pubkey_bin(S) || S <- Swarms],

    %% G1 takes input and broadcasts
    G1Args = [relcast_handler, [Members, input_multicast(), undefined], [{create, true}]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles a message by acknowledging it
    G2Args = [relcast_handler, [Members, undefined, handle_msg([])], [{create, true}]],
    {ok, _G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    %% G3 handles a messages by aknowledging it
    G3Args = [relcast_handler, [Members, undefined, handle_msg([])], [{create, true}]],
    {ok, _G3} = libp2p_swarm:add_group(S3, "test", libp2p_group_relcast, G3Args),

    libp2p_group_relcast:handle_input(G1, <<"multicast">>),

    Messages = receive_messages([], 2),
    %% Messages are delivered at least once
    true = length(Messages) >= 2,

    true = is_map(libp2p_group_relcast:info(G1)),

    ok.


defer_test(Config) ->
    Swarms = [S1, S2] = ?config(swarms, Config),

    test_util:connect_swarms(S1, S2),

    test_util:await_gossip_groups(Swarms),
    test_util:await_gossip_streams(Swarms),

    Members = [libp2p_swarm:pubkey_bin(S) || S <- Swarms],

    %% G1 takes input and unicasts it to G2
    G1Args = [relcast_handler, [Members, input_unicast(2), handle_msg([])], [{create, true}]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles a message by deferring it
    G2Args = [relcast_handler, [Members, input_unicast(1), handle_msg(defer)], [{create, true}]],
    {ok, G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    libp2p_group_relcast:handle_input(G1, <<"defer">>),

    %% G2 should receive the message at least once from G1 even though it defers it
    Msgs1 = receive_messages([], 1),
    ct:pal("messages 1 ~p", [Msgs1]),
    true = lists:member({handle_msg, 1, <<"defer">>}, Msgs1),

    %% Then we ack it by telling G2 to ack for G1
    %libp2p_group_relcast:send_ack(G2, 1),
    libp2p_group_relcast:handle_input(G2, undefer),

    %% Send a message from G2 to G1
    libp2p_group_relcast:handle_input(G2, <<"defer2">>),

    %% Which G1 should see as a message from G2
    test_util:wait_until(
      fun() ->
              lists:member({handle_msg, 2, <<"defer2">>}, receive_messages([], 1))
      end),

    true = is_map(libp2p_group_relcast:info(G1)),
    ok.


close_test(Config) ->
    Swarms = [S1, S2] = ?config(swarms, Config),

    test_util:connect_swarms(S1, S2),

    test_util:await_gossip_groups(Swarms),
    test_util:await_gossip_streams(Swarms),

    Members = [libp2p_swarm:pubkey_bin(S) || S <- Swarms],

    %% G1 takes input and broadcasts
    G1Args = [relcast_handler, [Members, input_multicast(), undefined], [{create, true}]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles a message by closing
    G2Args = [relcast_handler, [Members, undefined, handle_msg([{stop, 5000}])], [{create, true}]],
    {ok, G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    libp2p_group_relcast:handle_input(G1, <<"multicast">>),

    Messages = receive_messages([], 1),
    %% Messages are delivered at least once
    true = length(Messages) >= 1,

    %% G2 hould have indicated close state. Kill the connection
    %% between S1 and S2. S1 may reconnect to S2 but S2 should not
    %% attempt to reconnect to S1.
    test_util:disconnect_swarms(S1, S2),

    test_util:wait_until(
      fun() ->
              not erlang:is_process_alive(G2)
      end),

    test_util:wait_until(
      fun() ->
              false == libp2p_config:lookup_group(libp2p_swarm:tid(S2), "test")
      end),
    ok.

pipeline_test(Config) ->
    [S1, S2, _S3] = ?config(swarms, Config),

    Swarms = [S1, S2],

    ct:pal("self ~p", [self()]),

    test_util:connect_swarms(S1, S2),

    test_util:await_gossip_groups(Swarms),
    test_util:await_gossip_streams(Swarms),

    Members = [libp2p_swarm:address(S) || S <- Swarms],

    %% g1 handles input by sending a lot of messages
    G1Args = [relcast_handler,
              [Members, many_messages(20, {unicast, 2, <<"unicast1">>}),
               handle_msg([])], [{create, true}]],
    {ok, G1} = libp2p_swarm:add_group(S1, "test", libp2p_group_relcast, G1Args),

    %% G2 handles a message by acknowledging it
    G2Args = [relcast_handler, [Members, undefined, handle_msg([])], [{create, true}]],
    {ok, G2} = libp2p_swarm:add_group(S2, "test", libp2p_group_relcast, G2Args),

    libp2p_group_relcast:handle_input(G2, {limit, 10}),

    %% Give G1 some input. This should end up getting to G2 who then
    %% sends a message to G3.
    libp2p_group_relcast:handle_input(G1, <<"unicast">>),

    %% add some sequence numbers to make sure we're getting stuff in
    %% the expected order.
    [receive
         {handle_msg, 1, <<"unicast1">>} -> ok;
         Unexpected -> error({unexpected, N, Unexpected})
     after 2000 ->
             error({timeout, N})
     end
     || N <- lists:seq(1, 11)],

    %% look for one more message, we should time out because the
    %% remote receiver has stopped
    receive
        {handle_msg, 1, <<"unicast1">>} ->
            error(should_timeout)
    after 2000 ->
            ok
    end,

    %% here we should check to make sure that we have some pending
    %% messages

    %% here we should restart G2 to make sure that everything gets
    %% resent
    ok.


restart_test(_Config) ->
    %% Restarting a relcast group should resend outbound messages that
    %% were not acknowledged, and re-deliver inbould messages to the
    %% handler.
    ok.


%% Utils
%%

input_unicast(Index) ->
    fun(Msg) ->
            ct:pal("command ~p unicast ~p ~p", [self(), Index, Msg]),
           [{unicast, Index, Msg}]
    end.

input_multicast() ->
    fun(Msg) ->
            [{multicast, Msg}]
    end.

many_messages(Count, Msg) ->
    fun(_) ->
            ct:pal("sending ~p copies of ~p", [Count, Msg]),
            lists:duplicate(Count, Msg)
    end.

handle_msg(Resp) ->
    Parent = self(),
    fun(Index, Msg) ->
            ct:pal("message ~p ! ~p: ~p ~p", [self(), Parent, Index, Msg]),
            Parent ! {handle_msg, Index, Msg},
            Resp
    end.

receive_messages(Acc, ExpectedCount) ->
    Ref = erlang:send_after(40000, self(), receive_message_timeout),
    receive_messages_(Acc, ExpectedCount, Ref).

receive_messages_(Acc, 0, Ref) ->
    erlang:cancel_timer(Ref),
    Acc;
receive_messages_(Acc, ExpectedCount, Ref) ->
    receive
        receive_message_timeout ->
            Acc;
        Msg ->
            ct:pal("Got message ~p", [Msg]),
            receive_messages_([Msg | Acc], ExpectedCount - 1, Ref)
    end.
