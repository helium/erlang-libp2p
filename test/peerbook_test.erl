-module(peerbook_test).

-include_lib("eunit/include/eunit.hrl").

mk_sigfun(PrivKey) ->
    fun(Bin) -> public_key:sign(Bin, sha256, PrivKey) end.


isolated_test_() ->
    {foreach,
     fun() ->
             Name = list_to_atom("swarm" ++ integer_to_list(erlang:monotonic_time())),
             TID = ets:new(Name, [public, ordered_set, {read_concurrency, true}]),
             ets:insert(TID, {swarm_name, Name}),
             {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
             ets:insert(TID, {swarm_address, CompactKey}),
             {ok, Pid} = libp2p_peerbook:start_link(TID, mk_sigfun(PrivKey)),
             {Pid, CompactKey, Name}
     end,
     fun ({Pid, _, Name}) ->
             Ref = erlang:monitor(process, Pid),
             exit(Pid, normal),
             receive
                 {'DOWN', Ref, process, Pid, _Reason} -> ok
             after 1000 ->
                     error(timeout)
             end,
             DirName = filename:join(libp2p_config:data_dir(), Name),
             test_util:rm_rf(DirName)
     end,
     test_util:with(
       [ {"Accessors", fun accessors/1},
         {"Bad Peer", fun bad_peer/1},
         {"Put Notifications", fun put/1}
       ])}.

mk_peer() ->
    {ok, PrivKey, PubKey} = ecc_compact:generate_key(),
    {ok, _, PubKey2} = ecc_compact:generate_key(),
    libp2p_peer:new(PubKey, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                    static, erlang:system_time(seconds),
                    mk_sigfun(PrivKey)).


accessors({PeerBook, Address, _Name}) ->
    Peer1 = mk_peer(),
    Peer2 = mk_peer(),

    libp2p_peerbook:put(PeerBook, [Peer1]),
    libp2p_peerbook:put(PeerBook, [Peer2]),

    io:format("KEYS ~p", [libp2p_peerbook:keys(PeerBook)]),
    ?assert(libp2p_peerbook:is_key(PeerBook, Address)),
    ?assert(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer1))),
    ?assert(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer2))),

    ExpectedKeys = sets:from_list([Address,
                                   libp2p_peer:address(Peer1),
                                   libp2p_peer:address(Peer2)]),
    StoredKeys = sets:from_list(libp2p_peerbook:keys(PeerBook)),
    ?assertEqual(0, sets:size(sets:subtract(ExpectedKeys, StoredKeys))),

    ?assertNot(libp2p_peerbook:is_key(PeerBook, <<"foo">>)),
    ?assertEqual({error, not_found}, libp2p_peerbook:get(PeerBook, <<"foo">>)),

    %% Test removal
    ok = libp2p_peerbook:remove(PeerBook, libp2p_peer:address(Peer1)),
    ?assertNot(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer1))),
    ?assertEqual({error, no_delete}, libp2p_peerbook:remove(PeerBook, Address)),

    ok.

bad_peer({PeerBook, _Address, _Name}) ->
    {ok, _PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),

    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    InvalidPeer = libp2p_peer:new(PubKey1, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                                  static, erlang:system_time(), SigFun2),

    ?assertError(invalid_signature, libp2p_peerbook:put(PeerBook, [InvalidPeer])),
    ?assertNot(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(InvalidPeer))),

    ok.


put({PeerBook, Address, _Name}) ->
    PeerList1 = [mk_peer() || _ <- lists:seq(1, 5)],

    ExtraPeers = [mk_peer() || _ <- lists:seq(1, 3)],
    PeerList2 = lists:sublist(PeerList1, 1, 3) ++ ExtraPeers,

    ok = libp2p_peerbook:put(PeerBook, PeerList1),
    ?assert(lists:all(fun(P) ->
                              libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(P) )
                      end, PeerList1)),

    libp2p_peerbook:join_notify(PeerBook, self()),

    Parent = self(),
    spawn_link(fun() ->
                       ok = libp2p_peerbook:put(PeerBook, PeerList2),
                       Parent ! done
               end),
    receive
        done -> ok
    end,
    ?assert(lists:all(fun(P) ->
                              libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(P) )
                      end, ExtraPeers)),

    ReceivedPeers = receive
                        {new_peers, L} -> L
                    end,
    ?assertEqual(ExtraPeers, ReceivedPeers),

    {ok, ThisPeer} = libp2p_peerbook:get(PeerBook, Address),
    KnownValues = sets:from_list(PeerList1 ++ PeerList2 ++ [ThisPeer]),
    PeerBookValues = sets:from_list(libp2p_peerbook:values(PeerBook)),
    DiffValues = sets:subtract(PeerBookValues, KnownValues),
    ?assertEqual(0, sets:size(DiffValues)),

    ok.


swarm_test_() ->
    test_util:foreachx(
      [
       {"Peerbook Gossip", 2, [{libp2p_group_gossip,
                                [{peerbook_connections, 0}]
                               }], fun gossip/1},
       {"Peerbook Staletime", 1, [{libp2p_peerbook, [{stale_time, 200},
                                                     {peer_time, 400}]
                                  }], fun stale/1}
      ]).

gossip([S1, S2]) ->
    [S2ListenAddr | _] = libp2p_swarm:listen_addrs(S2),

    {ok, S1Session} = libp2p_swarm:connect(S1, S2ListenAddr),

    S1PeerBook = libp2p_swarm:peerbook(S1),
    S2PeerBook = libp2p_swarm:peerbook(S2),
    S1Addr = libp2p_swarm:address(S1),
    S2Addr = libp2p_swarm:address(S2),

    %% Wait to see if S1 knowsabout S2
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


stale([S1]) ->
    PeerBook = libp2p_swarm:peerbook(S1),
    S1Addr = libp2p_swarm:address(S1),
    {ok, S1First} = libp2p_peerbook:get(PeerBook, S1Addr),

    Peer1 = mk_peer(),
    libp2p_peerbook:put(PeerBook, [Peer1]),

    %% This peer should remew itself after stale_time
    ?assertEqual(ok, test_util:wait_until(
                       fun() ->
                               {ok, S1Entry} = libp2p_peerbook:get(PeerBook, S1Addr),
                               libp2p_peer:supersedes(S1Entry, S1First)
                       end)),

    Peer1Addr = libp2p_peer:address(Peer1),
    ?assertEqual(ok, test_util:wait_until(
                       fun() ->
                               not libp2p_peerbook:is_key(PeerBook, Peer1Addr)
                       end)),
    ?assertEqual({error, not_found}, libp2p_peerbook:get(PeerBook, Peer1Addr)),

    libp2p_peerbook:join_notify(PeerBook, self()),
    libp2p_peerbook:update_nat_type(PeerBook, static),

    UpdatedPeer = receive
                      {new_peers, [P]} -> P
                  after 1000 -> error(timeout)
                  end,

    ?assertEqual(S1Addr, libp2p_peer:address(UpdatedPeer)),
    ?assert(libp2p_peer:supersedes(UpdatedPeer, S1First)),
    ?assertEqual(static, libp2p_peer:nat_type(UpdatedPeer)),

    ok.
