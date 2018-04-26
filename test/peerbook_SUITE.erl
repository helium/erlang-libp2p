-module(peerbook_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accessor_test/1, bad_peer_test/1, put_test/1, gossip_test/1, stale_test/1]).

all() ->
    [
     accessor_test
     , bad_peer_test
     , put_test
     , gossip_test
     , stale_test
    ].

init_per_testcase(accessor_test, Config) ->
    setup_peerbook(Config);
init_per_testcase(bad_peer_test, Config) ->
    setup_peerbook(Config);
init_per_testcase(put_test, Config) ->
    setup_peerbook(Config);
init_per_testcase(gossip_test, Config) ->
    Swarms = test_util:setup_swarms(2, [{libp2p_group_gossip,
                                         [{peerbook_connections, 0}]
                                        }]),
    [{swarms, Swarms} | Config];
init_per_testcase(stale_test, Config) ->
    Swarms = test_util:setup_swarms(1, [{libp2p_peerbook, [{stale_time, 200},
                                                           {peer_time, 400}]
                                        }]),
    [{swarms, Swarms} | Config].


end_per_testcase(accessor_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(bad_peer_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(put_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(gossip_test, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms);
end_per_testcase(stale_test, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).


%% Tests
%%

accessor_test(Config) ->
    {PeerBook, Address, _Name} = proplists:get_value(peerbook, Config),

    Peer1 = mk_peer(),
    Peer2 = mk_peer(),

    libp2p_peerbook:put(PeerBook, [Peer1]),
    libp2p_peerbook:put(PeerBook, [Peer2]),

    true = libp2p_peerbook:is_key(PeerBook, Address),
    true = libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer1)),
    true = libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer2)),

    ExpectedKeys = sets:from_list([Address,
                                   libp2p_peer:address(Peer1),
                                   libp2p_peer:address(Peer2)]),
    StoredKeys = sets:from_list(libp2p_peerbook:keys(PeerBook)),
    0 = sets:size(sets:subtract(ExpectedKeys, StoredKeys)),

    false = libp2p_peerbook:is_key(PeerBook, <<"foo">>),
    {error, not_found} = libp2p_peerbook:get(PeerBook, <<"foo">>),

    %% Test removal
    ok = libp2p_peerbook:remove(PeerBook, libp2p_peer:address(Peer1)),
    false = libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer1)),
    {error, no_delete} = libp2p_peerbook:remove(PeerBook, Address),

    ok.

bad_peer_test(Config) ->
    {PeerBook, _Address, _Name} = proplists:get_value(peerbook, Config),

    {ok, _PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),

    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    InvalidPeer = libp2p_peer:new(PubKey1, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                                  static, erlang:system_time(), SigFun2),

    {'EXIT', {invalid_signature, _}} = (catch libp2p_peerbook:put(PeerBook, [InvalidPeer])),
    false = libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(InvalidPeer)),

    ok.


put_test(Config) ->
    {PeerBook, Address, _Name} = proplists:get_value(peerbook, Config),

    PeerList1 = [mk_peer() || _ <- lists:seq(1, 5)],

    ExtraPeers = [mk_peer() || _ <- lists:seq(1, 3)],
    PeerList2 = lists:sublist(PeerList1, 1, 3) ++ ExtraPeers,

    ok = libp2p_peerbook:put(PeerBook, PeerList1),
    true = lists:all(fun(P) ->
                             libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(P) )
                     end, PeerList1),

    libp2p_peerbook:join_notify(PeerBook, self()),

    Parent = self(),
    spawn_link(fun() ->
                       ok = libp2p_peerbook:put(PeerBook, PeerList2),
                       Parent ! done
               end),
    receive
        done -> ok
    end,
    true = lists:all(fun(P) ->
                             libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(P) )
                     end, ExtraPeers),

    ExtraPeers = receive
                        {new_peers, L} -> L
                    end,

    {ok, ThisPeer} = libp2p_peerbook:get(PeerBook, Address),
    KnownValues = sets:from_list(PeerList1 ++ PeerList2 ++ [ThisPeer]),
    PeerBookValues = sets:from_list(libp2p_peerbook:values(PeerBook)),
    0 = sets:size(sets:subtract(PeerBookValues, KnownValues)),

    ok.


gossip_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),

    [S2ListenAddr | _] = libp2p_swarm:listen_addrs(S2),

    {ok, S1Session} = libp2p_swarm:connect(S1, S2ListenAddr),

    S1PeerBook = libp2p_swarm:peerbook(S1),
    S2PeerBook = libp2p_swarm:peerbook(S2),
    S1Addr = libp2p_swarm:address(S1),
    S2Addr = libp2p_swarm:address(S2),

    %% Wait to see if S1 knows about S2
    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S1PeerBook, S2Addr) end),
    %% And if S2 knows about S1
    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S2PeerBook, S1Addr) end),

    %% The S2 entry in S1 should end up containing the address of S1
    %% as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S2PeerInfo} = libp2p_peerbook:get(S1PeerBook, S2Addr),
                                      [S1Addr] == libp2p_peer:connected_peers(S2PeerInfo)
                              end),

    %% and the S1 entry in S2 should end up containing the address of
    %% S2 as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S1PeerInfo} = libp2p_peerbook:get(S2PeerBook, S1Addr),
                                      [S2Addr] == libp2p_peer:connected_peers(S1PeerInfo)
                              end),

    %% Close the session
    libp2p_session:close(S1Session),

    %% After the session closes S1 should no longer have S2 as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S1Info} = libp2p_peerbook:get(S1PeerBook, S1Addr),
                                      [] == libp2p_peer:connected_peers(S1Info)
                              end),

    %% And S2 should no longer have S1 as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S2Info} = libp2p_peerbook:get(S2PeerBook, S2Addr),
                                      [] == libp2p_peer:connected_peers(S2Info)
                              end),

    ok.


stale_test(Config) ->
    [S1] = proplists:get_value(swarms, Config),

    PeerBook = libp2p_swarm:peerbook(S1),
    S1Addr = libp2p_swarm:address(S1),
    {ok, S1First} = libp2p_peerbook:get(PeerBook, S1Addr),

    Peer1 = mk_peer(),
    libp2p_peerbook:put(PeerBook, [Peer1]),

    %% This peer should remew itself after stale_time
    ok = test_util:wait_until(
           fun() ->
                   {ok, S1Entry} = libp2p_peerbook:get(PeerBook, S1Addr),
                   libp2p_peer:supersedes(S1Entry, S1First)
           end),

    Peer1Addr = libp2p_peer:address(Peer1),
    ok =  test_util:wait_until(
            fun() ->
                    not libp2p_peerbook:is_key(PeerBook, Peer1Addr)
            end),
    {error, not_found} = libp2p_peerbook:get(PeerBook, Peer1Addr),

    libp2p_peerbook:join_notify(PeerBook, self()),
    libp2p_peerbook:update_nat_type(PeerBook, static),

    UpdatedPeer = receive
                      {new_peers, [P]} -> P
                  after 1000 -> error(timeout)
                  end,

    S1Addr =  libp2p_peer:address(UpdatedPeer),
    true = libp2p_peer:supersedes(UpdatedPeer, S1First),
    static =  libp2p_peer:nat_type(UpdatedPeer),

    ok.


%% Util
%%

mk_peer() ->
    {ok, PrivKey, PubKey} = ecc_compact:generate_key(),
    {ok, _, PubKey2} = ecc_compact:generate_key(),
    libp2p_peer:new(PubKey, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                    static, erlang:system_time(seconds),
                    libp2p_crypto:mk_sig_fun(PrivKey)).

setup_peerbook(Config) ->
    Name = list_to_atom("swarm" ++ integer_to_list(erlang:monotonic_time())),
    TID = ets:new(Name, [public, ordered_set, {read_concurrency, true}]),
    ets:insert(TID, {swarm_name, Name}),
    {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
    ets:insert(TID, {swarm_address, CompactKey}),
    {ok, Pid} = libp2p_peerbook:start_link(TID, libp2p_crypto:mk_sig_fun(PrivKey)),
    [{peerbook, {Pid, CompactKey, Name}} | Config].

teardown_peerbook(Config) ->
    {Pid, _, Name} = proplists:get_value(peerbook, Config),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, normal),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
            error(timeout)
             end,
    DirName = filename:join(libp2p_config:data_dir(), [Name]),
    test_util:rm_rf(DirName).
