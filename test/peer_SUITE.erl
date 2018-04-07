-module(peer_SUITE).

-export([all/0]).
-export([coding_test/1]).

all() ->
    [coding_test].

coding_test(_) ->
    {ok, PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),
    SigFun1 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey1) end,
    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    Peer1 = libp2p_peer:new(PubKey1, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                           static, erlang:system_time(), SigFun1),

    DecodedPeer = libp2p_peer:decode(libp2p_peer:encode(Peer1)),

    true = libp2p_peer:address(Peer1) == libp2p_peer:address(DecodedPeer),
    true = libp2p_peer:timestamp(Peer1) ==  libp2p_peer:timestamp(DecodedPeer),
    true = libp2p_peer:listen_addrs(Peer1) == libp2p_peer:listen_addrs(DecodedPeer),
    true = libp2p_peer:nat_type(Peer1) ==  libp2p_peer:nat_type(DecodedPeer),
    true = libp2p_peer:connected_peers(Peer1) == libp2p_peer:connected_peers(DecodedPeer),

    InvalidPeer = libp2p_peer:new(PubKey1, ["/ip4/8.8.8.8/tcp/1234"], [PubKey2],
                                  static, erlang:system_time(), SigFun2),

    {'EXIT', {invalid_signature, _}} = (catch libp2p_peer:decode(libp2p_peer:encode(InvalidPeer))),

    % Check peer list coding
    Peer2 = libp2p_peer:new(PubKey2, ["/ip4/8.8.8.8/tcp/5678"], [PubKey1],
                            static, erlang:system_time(), SigFun2),

    [Peer1, Peer2] = libp2p_peer:decode_list(libp2p_peer:encode_list([Peer1, Peer2])),

    ok.
