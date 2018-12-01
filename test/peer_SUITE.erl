-module(peer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0]).
-export([coding_test/1, metadata_test/1, blacklist_test/1, association_test/1]).

all() ->
    [coding_test,
     metadata_test,
     blacklist_test,
     association_test
    ].

coding_test(_) ->
    {ok, PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),
    SigFun1 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey1) end,
    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    {ok, AssocPrivKey1, AssocPubKey1} = ecc_compact:generate_key(),
    AssocSigFun1 = fun(Bin) -> public_key:sign(Bin, sha256, AssocPrivKey1) end,
    Associations = [libp2p_peer:mk_association(AssocPubKey1, PubKey1, AssocSigFun1)
                   ],
    Peer1Map = #{address => PubKey1,
                 listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                 connected => [PubKey2],
                 nat_type => static,
                 associations => Associations
                },
    Peer1 = libp2p_peer:from_map(Peer1Map, SigFun1),

    DecodedPeer = libp2p_peer:decode(libp2p_peer:encode(Peer1)),

    ?assert(libp2p_peer:address(Peer1) == libp2p_peer:address(DecodedPeer)),
    ?assert(libp2p_peer:timestamp(Peer1) ==  libp2p_peer:timestamp(DecodedPeer)),
    ?assert(libp2p_peer:listen_addrs(Peer1) == libp2p_peer:listen_addrs(DecodedPeer)),
    ?assert(libp2p_peer:nat_type(Peer1) ==  libp2p_peer:nat_type(DecodedPeer)),
    ?assert(libp2p_peer:connected_peers(Peer1) == libp2p_peer:connected_peers(DecodedPeer)),
    ?assert(libp2p_peer:metadata(Peer1) == libp2p_peer:metadata(DecodedPeer)),
    ?assert(libp2p_peer:associations(Peer1) == libp2p_peer:associations(DecodedPeer)),

    ?assert(libp2p_peer:is_similar(Peer1, DecodedPeer)),

    InvalidPeer = libp2p_peer:from_map(Peer1Map, SigFun2),

    ?assertError(invalid_signature, libp2p_peer:decode(libp2p_peer:encode(InvalidPeer))),

    % Check peer list coding
    Peer2 = libp2p_peer:from_map(#{address => PubKey2,
                                   listen_addrs => ["/ip4/8.8.8.8/tcp/5678"],
                                   connected => [PubKey1],
                                   nat_type => static},
                                 SigFun2),

    ?assert(not libp2p_peer:is_similar(Peer1, Peer2)),
    ?assertEqual([Peer1, Peer2], libp2p_peer:decode_list(libp2p_peer:encode_list([Peer1, Peer2]))),

    ok.

metadata_test(_) ->
    {ok, PrivKey1, PubKey1} = ecc_compact:generate_key(),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    PeerMap = #{address => PubKey1,
                listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                connected => [],
                nat_type => static},
    Peer = libp2p_peer:from_map(PeerMap, SigFun1),

    Excludes = ["/ip4/8.8.8.8/tcp/1234"],
    MPeer = libp2p_peer:metadata_put(Peer, "exclude", term_to_binary(Excludes)),

    ?assertEqual(Excludes, binary_to_term(libp2p_peer:metadata_get(MPeer, "exclude", <<>>))),
    %% metadat does not affect similarity. Changing this behavior will
    %% BREAK peer gossiping so be very careful.
    ?assert(libp2p_peer:is_similar(MPeer, Peer)),

    %% Transmit metadata as part of peer encode/decode
    DecodedPeer = libp2p_peer:decode(libp2p_peer:encode(MPeer)),
    ?assertEqual(libp2p_peer:metadata(MPeer), libp2p_peer:metadata(DecodedPeer)),

    %% But metadata is NOT transmitted as part of an encoded list of
    %% peers. This avoids metedata being gossipped around. It's
    %% untrusted, and mostly only locally relevant
    ?assertEqual([Peer], libp2p_peer:decode_list(libp2p_peer:encode_list([MPeer]))),

    ok.

blacklist_test(_) ->
    {ok, PrivKey1, PubKey1} = ecc_compact:generate_key(),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    BadListenAddr = "/ip4/8.8.8.8/tcp/1234",
    GoodListenAddr =  "/ip4/1.1.1.1/tcp/4321",
    PeerMap = #{address => PubKey1,
                listen_addrs => [BadListenAddr, GoodListenAddr],
                connected => [],
                nat_type => static},
    Peer = libp2p_peer:from_map(PeerMap, SigFun1),

    MPeer = libp2p_peer:blacklist_add(Peer, BadListenAddr),

    ?assertEqual([BadListenAddr], libp2p_peer:blacklist(MPeer)),
    ?assert(libp2p_peer:is_blacklisted(MPeer, BadListenAddr)),
    ?assertEqual([GoodListenAddr], libp2p_peer:cleared_listen_addrs(MPeer)),

    ok.

association_test(_) ->
    {ok, PrivKey1, PubKey1} = ecc_compact:generate_key(),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    PeerMap = #{address => PubKey1,
                listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                connected => [],
                nat_type => static},

    {ok, AssocPrivKey1, AssocPubKey1} = ecc_compact:generate_key(),
    ValidAssoc = libp2p_peer:mk_association(AssocPubKey1, PubKey1,
                                            libp2p_crypto:mk_sig_fun(AssocPrivKey1)),
    ValidPeer = libp2p_peer:from_map(PeerMap#{associations => [ValidAssoc]}, SigFun1),

    ?assert(libp2p_peer:is_association(ValidPeer, AssocPubKey1)),
    ?assert(not libp2p_peer:is_association(ValidPeer, PubKey1)),
    ?assertEqual([ValidAssoc], libp2p_peer:associations(ValidPeer)),

    %% Make an association signed with the wrong private key
     InvalidAssoc = libp2p_peer:mk_association(AssocPubKey1, PubKey1, SigFun1),
    InvalidPeer = libp2p_peer:from_map(PeerMap#{associations => [InvalidAssoc]}, SigFun1),

    ?assertError(invalid_association_signature, libp2p_peer:verify(InvalidPeer)),

    ok.
