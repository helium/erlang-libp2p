-module(peerbook_test).

-include_lib("eunit/include/eunit.hrl").

mk_sigfun(PrivKey) ->
    fun(Bin) -> public_key:sign(Bin, sha256, PrivKey) end.

mk_peerbook() ->
    Name = list_to_atom("swarm" ++ integer_to_list(erlang:monotonic_time())),
    TID = ets:new(Name, [public, ordered_set, {read_concurrency, true}]),
    ets:insert(TID, {swarm_name, Name}),
    {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
    ets:insert(TID, {swarm_address, CompactKey}),
    {ok, Pid} = libp2p_peerbook:start_link(TID, mk_sigfun(PrivKey)),
    {Pid, CompactKey, Name}.

clear_peerbook(Name) ->
    DirName = filename:join(libp2p_config:data_dir(), Name),
    test_util:rm_rf(DirName).

mk_peer() ->
    {ok, PrivKey, PubKey} = ecc_compact:generate_key(),
    {ok, _, PubKey2} = ecc_compact:generate_key(),
    libp2p_peer:new(PubKey, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                    static, erlang:system_time(), mk_sigfun(PrivKey)).


basic_test() ->
    {PeerBook, Address, Name} = mk_peerbook(),

    Peer1 = mk_peer(),
    Peer2 = mk_peer(),

    libp2p_peerbook:put(PeerBook, [Peer1]),
    libp2p_peerbook:put(PeerBook, [Peer2]),

    ?assert(libp2p_peerbook:is_key(PeerBook, Address)),
    ?assert(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer1))),
    ?assert(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(Peer2))),

    ?assertNot(libp2p_peerbook:is_key(PeerBook, <<"foo">>)),

    clear_peerbook(Name).

bad_peer_test() ->
    {PeerBook, _Address, Name} = mk_peerbook(),

    {ok, _PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),

    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    InvalidPeer = libp2p_peer:new(PubKey1, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                                  static, erlang:system_time(), SigFun2),

    ?assertError(invalid_signature, libp2p_peerbook:put(PeerBook, [InvalidPeer])),
    ?assertNot(libp2p_peerbook:is_key(PeerBook, libp2p_peer:address(InvalidPeer))),

    clear_peerbook(Name).

put_test() ->
    {PeerBook, Address, Name} = mk_peerbook(),

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

    clear_peerbook(Name).


gossip_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    [S2ListenAddr | _] = libp2p_swarm:listen_addrs(S2),

    libp2p_swarm:connect(S1, S2ListenAddr),

    S1PeerBook = libp2p_swarm:peerbook(S1),
    S2Addr = libp2p_swarm:address(S2),

    ok = test_util:wait_until(fun() -> libp2p_peerbook:is_key(S1PeerBook, S2Addr) end),

    test_util:teardown_swarms(Swarms).
