-module(group_gossip_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-behavior(libp2p_group_gossip_handler).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([connection_test/1, gossip_test/1, seed_test/1]).
-export([forwards_compat_gossip_test/1, backwards_compat_gossip_test/1]).
-export([same_path_gossip_test1/1, same_path_gossip_test2/1]).
-export([init_gossip_data/1, handle_gossip_data/3]).

all() ->
    [
      connection_test
    , gossip_test
    , seed_test
    , backwards_compat_gossip_test
    , forwards_compat_gossip_test
    , same_path_gossip_test1
    , same_path_gossip_test2
    ].


init_per_testcase(seed_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    %% Set up S2 as the seed.
    [S2] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 0}]},
                                       {base_dir, ?config(base_dir, Config0)}
                                     ]),

    [S2ListenAddr | _] = libp2p_swarm:listen_addrs(S2),

    %% Set up S1 to be the client..one peer connection, and S2 as the seed node
    [S1] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip,
                                        [ {peerbook_connections, 0},
                                          {seed_nodes, [S2ListenAddr]}
                                        ]},
                                       {base_dir, ?config(base_dir, Config0)}
                                     ]),
    [{swarms, [S1, S2]} | Config];


init_per_testcase(TestCase, Config) when TestCase == forwards_compat_gossip_test;
                                         TestCase ==  backwards_compat_gossip_test;
                                         TestCase == same_path_gossip_test1;
                                         TestCase == same_path_gossip_test2 ->

    test_util:init_base_dir_config(?MODULE, TestCase, Config);

init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms(2, [
                                        {libp2p_group_gossip,
                                         [{peerbook_connections, 1},
                                          {peer_cache_timeout, 100}]
                                        },
                                        {base_dir, ?config(base_dir, Config0)} ]),
    [{swarms, Swarms} | Config].

end_per_testcase(_TestCase, _Config) when _TestCase == forwards_compat_gossip_test;
                                         _TestCase ==  backwards_compat_gossip_test;
                                         _TestCase == same_path_gossip_test1;
                                         _TestCase == same_path_gossip_test2 ->
    ok;
end_per_testcase(_, Config) ->
    Swarms = ?config(swarms, Config),
    test_util:teardown_swarms(Swarms).


connection_test(Config) ->
    [S1, S2] = ?config(swarms, Config),

    %% Add S2 to the S1 peerbook. This shoud cause the S1 group
    %% to connect to S2
    S1PeerBook = libp2p_swarm:peerbook(S1),

    %% No initial sessions since peerbook is empty
    S1Group = libp2p_swarm:gossip_group(S1),
    ?assertEqual([], libp2p_group_gossip:connected_addrs(S1Group, peerbook)),

    %% Fake a drop timer to see if sessions are attempted
    S1Group ! drop_timeout,
    ?assertEqual([], libp2p_group_gossip:connected_addrs(S1Group, peerbook)),

    %% Now tell S1 about S2
    libp2p_peerbook:put(S1PeerBook, [get_peer(S2)]),

    %% Verify that S2 finds out about S1
    S2PeerBook = libp2p_swarm:peerbook(S2),
    ok = test_util:wait_until(fun() ->
                                      libp2p_peerbook:is_key(S2PeerBook, libp2p_swarm:pubkey_bin(S1))
                              end),
    %% And that the S1 gossip group is "conneted" to S2.
    ?assert(lists:member(libp2p_swarm:p2p_address(S2),
                         libp2p_group_gossip:connected_addrs(S1Group, peerbook))),

    %% Make S1 forget about S2
    libp2p_peerbook:remove(S1PeerBook, libp2p_swarm:pubkey_bin(S2)),

    %% And fake a timeout to ensure that the group forgets about S2
    S1Group ! drop_timeout,
    ?assertEqual([], libp2p_group_gossip:connected_addrs(S1Group, peerbook)),

    %% Sending to a gossip group without a stream client config should fail silently
    libp2p_group_gossip:send(S1Group, "flip", <<"no way">>),

    ok.


gossip_test(Config) ->
    timer:sleep(1000),

    Swarms = [S1, S2] = ?config(swarms, Config),

    S1Group = libp2p_swarm:gossip_group(S1),
    libp2p_group_gossip:add_handler(S1Group, "gossip_test", {?MODULE, self()}),

    test_util:connect_swarms(S1, S2),

    test_util:await_gossip_groups(Swarms),
    test_util:await_gossip_streams(Swarms),

    S2Group = libp2p_swarm:gossip_group(S2),
    libp2p_group_gossip:send(S2Group, "gossip_test", <<"hello">>),

    receive
        {handle_gossip_data, <<"hello">>} -> ok
    after 5000 -> error(timeout)
    end,

    ok.


forwards_compat_gossip_test(Config) ->
    %% NOTE: declaring swarms in test here as the order of declaration matters
    %% the first swarm declared will be the one to dial, so this test declares in the order it requires
    %% keep the swarm declarations here until this is worked out
    %% S1 ( gossip/1.0.0 ) will dial S2 ( gossip/1.0.2 / gossip/1.0.0 )
    %% S1 will gossip to S2
    [S1] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),

    [S2] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.2", "gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),

    timer:sleep(1000),

    %% add handlers for S1
    S1Group = libp2p_swarm:gossip_group(S1),
    libp2p_group_gossip:add_handler(S1Group, "gossip/1.0.0", {?MODULE, self()}),

    %% add handlers for S2
    S2Group = libp2p_swarm:gossip_group(S2),
    libp2p_group_gossip:add_handler(S2Group, "gossip/1.0.2", {?MODULE, self()}),
    libp2p_group_gossip:add_handler(S2Group, "gossip/1.0.0", {?MODULE, self()}),

    %% connect the swarms and wait until they are fully ready
    connect_await_ready(S1, S2),

    %% send the msg from S1 to S2
    libp2p_group_gossip:send(S1Group, "gossip/1.0.0", <<"hello S2, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S2, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    %% send the msg from S2 to S1
    libp2p_group_gossip:send(S2Group, "gossip/1.0.0", <<"hello S1, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S1, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    test_util:teardown_swarms([S1,S2]),
    ok.

backwards_compat_gossip_test(Config) ->
    %% NOTE: declaring swarms in test here as the order of declaration matters
    %% the first swarm declared will be the one to dial, so this test declares in the order it requires
    %% keep the swarm declarations here until this is worked out

    %% S1 ( gossip/1.0.2 / gossip/1.0.0 ) will connect to S2 ( gossip/1.0.0 )
    %% S1 will gossip to S2, gossip/1.0.0 will be the negotiated path

    [S1] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.2", "gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),
    %% S2 represents an old swarm, so dont specifiy the gossip protocol in the config let it use default
    [S2] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),

    timer:sleep(1000),

    %% add handlers for S1
    S1Group = libp2p_swarm:gossip_group(S1),
    ct:pal("S1 group: ~p", [S1Group]),
    libp2p_group_gossip:add_handler(S1Group, "gossip/1.0.2", {?MODULE, self()}),
    libp2p_group_gossip:add_handler(S1Group, "gossip/1.0.0", {?MODULE, self()}),


    %% add handlers for S2
    S2Group = libp2p_swarm:gossip_group(S2),
    ct:pal("S2 group: ~p", [S2Group]),
    libp2p_group_gossip:add_handler(S2Group, "gossip/1.0.0", {?MODULE, self()}),

    %% connect the swarms and wait until they are fully ready
    connect_await_ready(S1, S2),

    %% send the msg from S1 to S2
    libp2p_group_gossip:send(S1Group, "gossip/1.0.0", <<"hello S2, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S2, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    %% send the msg from S2 to S1
    libp2p_group_gossip:send(S2Group, "gossip/1.0.0", <<"hello S1, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S1, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    test_util:teardown_swarms([S1,S2]),
    ok.


same_path_gossip_test1(Config) ->
    %% NOTE: declaring swarms in test here as the order of declaration matters
    %% the first swarm declared will be the one to dial, so this test declares in the order it requires
    %% keep the swarm declarations here until this is worked out
    %% S1 ( gossip/1.0.0 ) will connect to S2 ( gossip/1.0.0 )
    %% S2 will gossip to S3, gossip/1.0.0 will be the negotiated path

    [S1] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),

    [S2] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),

    timer:sleep(1000),

    %% add handlers for S1
    S1Group = libp2p_swarm:gossip_group(S1),
    libp2p_group_gossip:add_handler(S1Group, "gossip/1.0.0", {?MODULE, self()}),

    %% add handlers for S2
    S2Group = libp2p_swarm:gossip_group(S2),
    libp2p_group_gossip:add_handler(S2Group, "gossip/1.0.0", {?MODULE, self()}),

    %% connect the swarms and wait until they are fully ready
    connect_await_ready(S1, S2),

    %% send the msg from S1 to S2
    libp2p_group_gossip:send(S1Group, "gossip/1.0.0", <<"hello S2, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S2, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    %% send the msg from S2 to S1
    libp2p_group_gossip:send(S2Group, "gossip/1.0.0", <<"hello S1, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S1, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    test_util:teardown_swarms([S1,S2]),
    ok.


same_path_gossip_test2(Config) ->
    %% NOTE: declaring swarms in test here as the order of declaration matters
    %% the first swarm declared will be the one to dial, so this test declares in the order it requires
    %% keep the swarm declarations here until this is worked out
    %% S1 ( gossip/1.0.2 / gossip/1.0.0 ) will connect to S2 ( gossip/1.0.2 )
    %% S2 will gossip to S1, gossip/1.0.2 will be the negotiated path

    [S1] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.2", "gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),

    [S2] = test_util:setup_swarms(1, [
                                       {libp2p_group_gossip, [{peerbook_connections, 1},
                                                              {peer_cache_timeout, 100},
                                                              {supported_gossip_paths, ["gossip/1.0.2", "gossip/1.0.0"]}  ]},
                                       {base_dir, ?config(base_dir, Config)}
                                     ]),


    timer:sleep(1000),

    %% add handlers for S1
    S1Group = libp2p_swarm:gossip_group(S1),
    libp2p_group_gossip:add_handler(S1Group, "gossip/1.0.2", {?MODULE, self()}),
    libp2p_group_gossip:add_handler(S1Group, "gossip/1.0.0", {?MODULE, self()}),

    %% add handlers for S2
    S2Group = libp2p_swarm:gossip_group(S2),
    libp2p_group_gossip:add_handler(S2Group, "gossip/1.0.2", {?MODULE, self()}),
    libp2p_group_gossip:add_handler(S2Group, "gossip/1.0.0", {?MODULE, self()}),

    %% connect the swarms and wait until they are fully ready
    connect_await_ready(S1, S2),

    %% send the msg from S1 to S2
    libp2p_group_gossip:send(S1Group, "gossip/1.0.2", <<"hello S2, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S2, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    %% send the msg from S2 to S1
    libp2p_group_gossip:send(S2Group, "gossip/1.0.2", <<"hello S1, its me you're looking for">>),

    receive
        {handle_gossip_data, <<"hello S1, its me you're looking for">>} -> ok
    after 5000 -> error(timeout)
    end,

    test_util:teardown_swarms([S1,S2]),
    ok.


seed_test(Config) ->
    [S1, S2] = ?config(swarms, Config),

    %% Verify that S2 finds out about S1
    S2PeerBook = libp2p_swarm:peerbook(S2),
    ok = test_util:wait_until(fun() ->
                                      libp2p_peerbook:is_key(S2PeerBook, libp2p_swarm:pubkey_bin(S1))
                              end),

    %% And the S1 has a session to S2
    S1Group = libp2p_swarm:gossip_group(S1),
    ?assertEqual([], libp2p_group_gossip:connected_addrs(S1Group, peerbook)),
    ?assertEqual(1, length(libp2p_group_gossip:connected_addrs(S1Group, seed))),

    ok.

%% Utils

init_gossip_data(_) ->
     ok.

handle_gossip_data(_StreamPid, Msg, Parent) ->
    Parent ! {handle_gossip_data, Msg},
    noreply.

get_peer(Swarm) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    Addr = libp2p_swarm:pubkey_bin(Swarm),
    {ok, Peer} = libp2p_peerbook:get(PeerBook, Addr),
    Peer.

connect_await_ready(S1, S2)->
    test_util:connect_swarms(S1, S2),
    %% wait until we are fully connected
    test_util:await_gossip_groups([S1, S2]),
    test_util:await_gossip_streams([S1, S2]).
