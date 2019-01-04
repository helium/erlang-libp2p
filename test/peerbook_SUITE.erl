-module(peerbook_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accessor_test/1, bad_peer_test/1, put_test/1, blacklist_test/1,
         association_test/1, gossip_test/1, stale_test/1]).

all() ->
    [
     accessor_test,
     bad_peer_test,
     put_test,
     gossip_test,
     stale_test,
     blacklist_test,
     association_test
    ].

init_per_testcase(accessor_test, Config) ->
    setup_peerbook(Config, []);
init_per_testcase(bad_peer_test, Config) ->
    setup_peerbook(Config, []);
init_per_testcase(blacklist_test, Config) ->
    setup_peerbook(Config, []);
init_per_testcase(association_test, Config) ->
    setup_peerbook(Config, []);
init_per_testcase(put_test, Config) ->
    setup_peerbook(Config, [{libp2p_peerbook, [{notify_time, 200}]
                            }]);
init_per_testcase(gossip_test, Config) ->
    Swarms = test_util:setup_swarms(2, [{libp2p_group_gossip,
                                         [{peerbook_connections, 1}]
                                        },
                                        {libp2p_peerbook,
                                         [{notify_time, 500},
                                          {peer_time, 400}]
                                        }]),
    [{swarms, Swarms} | Config];
init_per_testcase(stale_test, Config) ->
    Swarms = test_util:setup_swarms(1, [{libp2p_peerbook, [{stale_time, 100},
                                                           {peer_time, 400},
                                                           {notify_time, 500}]
                                        }]),
    [{swarms, Swarms} | Config].


end_per_testcase(accessor_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(bad_peer_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(blacklist_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(association_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(put_test, Config) ->
    teardown_peerbook(Config);
end_per_testcase(gossip_test, Config) ->
    [S1, _S2] = proplists:get_value(swarms, Config),
    test_util:teardown_swarms([S1]);
end_per_testcase(stale_test, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).


%% Tests
%%

accessor_test(Config) ->
    {_PeerBook, Address} = proplists:get_value(peerbook, Config),
    PeerBook = libp2p_swarm:peerbook(proplists:get_value(tid, Config)),

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
    PeerBook = libp2p_swarm:peerbook(proplists:get_value(tid, Config)),

    {ok, _PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),

    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    InvalidPeer = libp2p_peer:from_map(#{address => PubKey1,
                                         listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                                         connected => [PubKey2],
                                         nat_type => static,
                                         timestamp => erlang:system_time(millisecond)},
                                       SigFun2),

    {'EXIT', {invalid_signature, _}} = (catch libp2p_peerbook:put(PeerBook, [InvalidPeer])),
    false = libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(InvalidPeer)),

    ok.


blacklist_test(Config) ->
    {_PeerBook, _Address} = proplists:get_value(peerbook, Config),
    PeerBook = libp2p_swarm:peerbook(proplists:get_value(tid, Config)),

    Peer1 = mk_peer(),

    libp2p_peerbook:put(PeerBook, [Peer1]),

    [ListenAddr | _] = libp2p_peer:listen_addrs(Peer1),
    PeerAddr = libp2p_peer:address(Peer1),
    libp2p_peerbook:blacklist_listen_addr(PeerBook, PeerAddr, ListenAddr),

    {ok, GotPeer} = libp2p_peerbook:get(PeerBook, PeerAddr),
    libp2p_peer:is_blacklisted(GotPeer, ListenAddr),
    [] = libp2p_peer:cleared_listen_addrs(GotPeer),

    ok.


association_test(Config) ->
    {_PeerBook, Address} = proplists:get_value(peerbook, Config),
    PeerBook = libp2p_swarm:peerbook(proplists:get_value(tid, Config)),

    {ok, AssocPrivKey, AssocPubKey} = ecc_compact:generate_key(),
    AssocSigFun = libp2p_crypto:mk_sig_fun(AssocPrivKey),
    Assoc = libp2p_peer:mk_association(AssocPubKey, Address, AssocSigFun),

    ?assertEqual(ok, libp2p_peerbook:add_association(PeerBook, "wallet", Assoc)),

    timer:sleep(100),

    {ok, ThisPeer} = libp2p_peerbook:get(PeerBook, Address),
    ?assert(libp2p_peer:is_association(ThisPeer, "wallet", AssocPubKey)),

    %% Adding the same association twice should dedupe
    ?assertEqual(ok, libp2p_peerbook:add_association(PeerBook, "wallet", Assoc)),
    {ok, ThisPeer2} = libp2p_peerbook:get(PeerBook, Address),
    ?assertEqual(1, length(libp2p_peer:associations_get(ThisPeer2, "wallet"))),

    ok.

put_test(Config) ->
    {_PeerBook, Address} = proplists:get_value(peerbook, Config),
    PeerBook = libp2p_swarm:peerbook(proplists:get_value(tid, Config)),

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

    ReceivedPeers = receive
                        {new_peers, L} -> L
                    end,
    true = sets:is_subset(sets:from_list(peer_keys(ExtraPeers)), sets:from_list(peer_keys(ReceivedPeers))),

    {ok, ThisPeer} = libp2p_peerbook:get(PeerBook, Address),
    KnownValues = sets:from_list(PeerList1 ++ PeerList2 ++ [ThisPeer]),
    PeerBookValues = sets:from_list(libp2p_peerbook:values(PeerBook)),
    0 = sets:size(sets:subtract(PeerBookValues, KnownValues)),

    ok.


gossip_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),

    test_util:connect_swarms(S1, S2),

    S1PeerBook = libp2p_swarm:peerbook(S1),
    S2PeerBook = libp2p_swarm:peerbook(S2),
    S1Addr = libp2p_swarm:address(S1),
    S2Addr = libp2p_swarm:address(S2),


    S1Group = libp2p_swarm:gossip_group(S1),
    test_util:wait_until(fun() ->
                                 lists:member(libp2p_swarm:p2p_address(S2),
                                              libp2p_group_gossip:connected_addrs(S1Group, all))
                         end),
    S2Group = libp2p_swarm:gossip_group(S2),
    test_util:wait_until(fun() ->
                                 lists:member(libp2p_swarm:p2p_address(S1),
                                              libp2p_group_gossip:connected_addrs(S2Group, all))
                         end),

    %% The S2 entry in S1 should end up containing the address of S1
    %% as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S2PeerInfo} = libp2p_peerbook:get(S1PeerBook, S2Addr),
                                      lists:member(S1Addr, libp2p_peer:connected_peers(S2PeerInfo))
                              end),

    %% and the S1 entry in S2 should end up containing the address of
    %% S2 as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S1PeerInfo} = libp2p_peerbook:get(S2PeerBook, S1Addr),
                                      lists:member(S2Addr, libp2p_peer:connected_peers(S1PeerInfo))
                              end),

    %% Close the session by terminating the swarm
    libp2p_swarm:stop(S2),

    %% After the session closes S1 should no longer have S2 as a connected peer
    ok = test_util:wait_until(fun() ->
                                      {ok, S1Info} = libp2p_peerbook:get(S1PeerBook, S1Addr),
                                      [] == libp2p_peer:connected_peers(S1Info)
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
                   case libp2p_peerbook:get(PeerBook, S1Addr) of
                       {ok, S1Entry} ->
                           libp2p_peer:supersedes(S1Entry, S1First);
                       _ -> false
                   end
           end),

    Peer1Addr = libp2p_peer:address(Peer1),
    ok =  test_util:wait_until(
            fun() ->
                    not libp2p_peerbook:is_key(PeerBook, Peer1Addr)
            end),
    {error, not_found} = libp2p_peerbook:get(PeerBook, Peer1Addr),

    libp2p_peerbook:join_notify(PeerBook, self()),
    libp2p_peerbook:update_nat_type(PeerBook, static),

    ok = test_util:wait_until(
          fun() ->
                  UpdatedPeers = receive
                                     {new_peers, P} -> P
                                 after 500 -> undefined
                                 end,
                  case UpdatedPeers of
                      undefined -> ok;
                      _ ->
                          [UpdatedPeer] = lists:filter(fun(P) ->
                                                               libp2p_peer:address(P) == S1Addr
                                                       end, UpdatedPeers),
                          S1Addr == libp2p_peer:address(UpdatedPeer)
                              andalso true == libp2p_peer:supersedes(UpdatedPeer, S1First)
                              andalso static ==  libp2p_peer:nat_type(UpdatedPeer)
                  end
          end),
    ok.


%% Util
%%

peer_keys(PeerList) ->
    [libp2p_crypto:address_to_b58(libp2p_peer:address(P)) || P <- PeerList].

mk_peer() ->
    {ok, PrivKey, PubKey} = ecc_compact:generate_key(),
    {ok, _, PubKey2} = ecc_compact:generate_key(),
    libp2p_peer:from_map(#{address => PubKey,
                           listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                           connected => [PubKey2],
                           nat_type => static,
                           timestamp => erlang:system_time(millisecond)},
                         libp2p_crypto:mk_sig_fun(PrivKey)).

setup_peerbook(Config, Opts) ->
    test_util:setup(),
    Name = list_to_atom("swarm" ++ integer_to_list(erlang:monotonic_time())),
    TID = ets:new(Name, [public, ordered_set, {read_concurrency, true}]),
    ets:insert(TID, {swarm_name, Name}),
    {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
    ets:insert(TID, {swarm_address, CompactKey}),
    TmpDir = test_util:nonl(os:cmd("mktemp -d")),
    ets:insert(TID, {swarm_opts, lists:keystore(base_dir, 1, Opts, {base_dir, TmpDir})}),
    {ok, Pid} = libp2p_peerbook:start_link(TID, libp2p_crypto:mk_sig_fun(PrivKey)),
    [{peerbook, {Pid, CompactKey}}, {tid, TID} | Config].

teardown_peerbook(Config) ->
    {Pid, _} = proplists:get_value(peerbook, Config),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, normal),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
            error(timeout)
    end.
