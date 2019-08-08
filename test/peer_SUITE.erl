-module(peer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0]).
-export([coding_test/1, metadata_test/1, blacklist_test/1, association_test/1, signed_metadata_test/1]).

all() ->
    [coding_test,
     metadata_test,
     blacklist_test,
     association_test,
     signed_metadata_test
    ].

coding_test(_) ->
    #{public := PubKey1, secret := PrivKey1} = libp2p_crypto:generate_keys(ecc_compact),
    #{public := PubKey2, secret := PrivKey2} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),
    SigFun2 = libp2p_crypto:mk_sig_fun(PrivKey2),

    #{public := AssocPubKey1, secret := AssocPrivKey1} = libp2p_crypto:generate_keys(ecc_compact),
    AssocSigFun1 = libp2p_crypto:mk_sig_fun(AssocPrivKey1),
    Associations = [libp2p_peer:mk_association(libp2p_crypto:pubkey_to_bin(AssocPubKey1),
                                               libp2p_crypto:pubkey_to_bin(PubKey1),
                                               AssocSigFun1)
                   ],
    Peer1Map = #{pubkey => libp2p_crypto:pubkey_to_bin(PubKey1),
                 listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                 connected => [libp2p_crypto:pubkey_to_bin(PubKey2)],
                 nat_type => static,
                 associations => [{"wallet", Associations}]
                },
    Peer1 = libp2p_peer:from_map(Peer1Map, SigFun1),

    DecodedPeer = libp2p_peer:decode(libp2p_peer:encode(Peer1)),

    ?assert(libp2p_peer:pubkey_bin(Peer1) == libp2p_peer:pubkey_bin(DecodedPeer)),
    ?assert(libp2p_peer:timestamp(Peer1) ==  libp2p_peer:timestamp(DecodedPeer)),
    ?assert(libp2p_peer:listen_addrs(Peer1) == libp2p_peer:listen_addrs(DecodedPeer)),
    ?assert(libp2p_peer:nat_type(Peer1) ==  libp2p_peer:nat_type(DecodedPeer)),
    ?assert(libp2p_peer:connected_peers(Peer1) == libp2p_peer:connected_peers(DecodedPeer)),
    ?assert(libp2p_peer:metadata(Peer1) == libp2p_peer:metadata(DecodedPeer)),
    ?assert(libp2p_peer:association_pubkey_bins(Peer1) == libp2p_peer:association_pubkey_bins(DecodedPeer)),

    ?assert(libp2p_peer:is_similar(Peer1, DecodedPeer)),

    InvalidPeer = libp2p_peer:from_map(Peer1Map, SigFun2),

    ?assertError(invalid_signature, libp2p_peer:decode(libp2p_peer:encode(InvalidPeer))),

    % Check peer list coding
    Peer2 = libp2p_peer:from_map(#{pubkey => libp2p_crypto:pubkey_to_bin(PubKey2),
                                   listen_addrs => ["/ip4/8.8.8.8/tcp/5678"],
                                   connected => [libp2p_crypto:pubkey_to_bin(PubKey1)],
                                   nat_type => static},
                                 SigFun2),

    ?assert(not libp2p_peer:is_similar(Peer1, Peer2)),
    ?assertEqual([Peer1, Peer2], libp2p_peer:decode_list(libp2p_peer:encode_list([Peer1, Peer2]))),

    ok.

metadata_test(_) ->
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    PeerMap = #{pubkey => libp2p_crypto:pubkey_to_bin(PubKey1),
                listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                connected => [],
                nat_type => static},
    Peer = libp2p_peer:from_map(PeerMap, SigFun1),

    Excludes = ["/ip4/8.8.8.8/tcp/1234"],
    MPeer = libp2p_peer:metadata_put(Peer, "exclude", term_to_binary(Excludes)),

    ?assertEqual(Excludes, binary_to_term(libp2p_peer:metadata_get(MPeer, "exclude", <<>>))),
    %% metadata does not affect similarity. Changing this behavior will
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
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    BadListenAddr = "/ip4/8.8.8.8/tcp/1234",
    GoodListenAddr =  "/ip4/1.1.1.1/tcp/4321",
    PeerMap = #{pubkey => libp2p_crypto:pubkey_to_bin(PubKey1),
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
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    PeerMap = #{pubkey => libp2p_crypto:pubkey_to_bin(PubKey1),
                listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                connected => [],
                nat_type => static},

    #{secret := AssocPrivKey1, public := AssocPubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    ValidAssoc = libp2p_peer:mk_association(libp2p_crypto:pubkey_to_bin(AssocPubKey1),
                                            libp2p_crypto:pubkey_to_bin(PubKey1),
                                            libp2p_crypto:mk_sig_fun(AssocPrivKey1)),
    ValidPeer = libp2p_peer:from_map(PeerMap#{associations => [{"wallet", [ValidAssoc]}]}, SigFun1),

    ?assert(libp2p_peer:is_association(ValidPeer, "wallet",
                                       libp2p_crypto:pubkey_to_bin(AssocPubKey1))),
    ?assert(not libp2p_peer:is_association(ValidPeer, "wallet",
                                           libp2p_crypto:pubkey_to_bin(PubKey1))),
    ?assert(not libp2p_peer:is_association(ValidPeer, "no_such_type",
                                           libp2p_crypto:pubkey_to_bin(PubKey1))),
    ?assertEqual([{"wallet", [libp2p_crypto:pubkey_to_bin(AssocPubKey1)]}],
                 libp2p_peer:association_pubkey_bins(ValidPeer)),
    ?assertEqual([ValidAssoc], libp2p_peer:associations_get(ValidPeer, "wallet")),
    ?assertEqual([{"wallet", [ValidAssoc]}], libp2p_peer:associations(ValidPeer)),
    ?assert(libp2p_peer:verify(ValidPeer)),

    EncodedValidAssoc = libp2p_peer:association_encode(ValidAssoc),
    ?assertEqual(ValidAssoc, libp2p_peer:association_decode(EncodedValidAssoc,
                                                            libp2p_crypto:pubkey_to_bin(PubKey1))),

    %% Setting the same association dedupes
    ValidPeer2 = libp2p_peer:associations_put(ValidPeer, "wallet", ValidAssoc, SigFun1),
    ?assertEqual([ValidAssoc], libp2p_peer:associations_get(ValidPeer2, "wallet")),

    %% Make an association signed with the wrong private key
    InvalidAssoc = libp2p_peer:mk_association(libp2p_crypto:pubkey_to_bin(AssocPubKey1),
                                              libp2p_crypto:pubkey_to_bin(PubKey1), SigFun1),
    InvalidPeer = libp2p_peer:associations_put(ValidPeer, "wallet", InvalidAssoc, SigFun1),
    ?assert(libp2p_peer:is_association(InvalidPeer, "wallet",
                                       libp2p_crypto:pubkey_to_bin(AssocPubKey1))),
    ?assertEqual([InvalidAssoc], libp2p_peer:associations_get(InvalidPeer, "wallet")),

    ?assertError(invalid_association_signature, libp2p_peer:verify(InvalidPeer)),

    ok.

signed_metadata_test(_) ->
    #{secret := PrivKey1, public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun1 = libp2p_crypto:mk_sig_fun(PrivKey1),

    PeerMap = #{pubkey => libp2p_crypto:pubkey_to_bin(PubKey1),
                listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                connected => [],
                nat_type => static,
                signed_metadata => #{<<"hello">> => <<"world">>}},
    Peer = libp2p_peer:from_map(PeerMap, SigFun1),
    ?assertEqual(<<"world">>, libp2p_peer:signed_metadata_get(Peer, <<"hello">>, <<"dlrow">>)),
    ?assertEqual(<<"dlrow">>, libp2p_peer:signed_metadata_get(Peer, <<"goodbye">>, <<"dlrow">>)),
    ok.

