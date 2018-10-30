-module(peer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0]).
-export([coding_test/1, metadata_test/1]).

all() ->
    [coding_test,
     metadata_test].

coding_test(_) ->
    {ok, PrivKey1, PubKey1} = ecc_compact:generate_key(),
    {ok, PrivKey2, PubKey2} = ecc_compact:generate_key(),
    SigFun1 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey1) end,
    SigFun2 = fun(Bin) -> public_key:sign(Bin, sha256, PrivKey2) end,

    Peer1Map = #{address => PubKey1,
                 listen_addrs => ["/ip4/8.8.8.8/tcp/1234"],
                 connected => [PubKey2],
                 nat_type => static},
    Peer1 = libp2p_peer:from_map(Peer1Map, SigFun1),

    DecodedPeer = libp2p_peer:decode(libp2p_peer:encode(Peer1)),

    ?assert(libp2p_peer:address(Peer1) == libp2p_peer:address(DecodedPeer)),
    ?assert(libp2p_peer:timestamp(Peer1) ==  libp2p_peer:timestamp(DecodedPeer)),
    ?assert(libp2p_peer:listen_addrs(Peer1) == libp2p_peer:listen_addrs(DecodedPeer)),
    ?assert(libp2p_peer:nat_type(Peer1) ==  libp2p_peer:nat_type(DecodedPeer)),
    ?assert(libp2p_peer:connected_peers(Peer1) == libp2p_peer:connected_peers(DecodedPeer)),
    ?assert(libp2p_peer:metadata(Peer1) == libp2p_peer:metadata(DecodedPeer)),

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

    Blacklist = ["/ip4/8.8.8.8/tcp/1234"],
    Metadata = [{"blacklist", term_to_binary(Blacklist)}],
    MPeer = libp2p_peer:set_metadata(Peer, Metadata),

    ?assertEqual(Metadata, libp2p_peer:metadata(MPeer)),
    %% metadat does not affect similarity. Changing this behavior will
    %% BREAK peer gossiping so be very careful.
    ?assert(libp2p_peer:is_similar(MPeer, Peer)),

    %% Transmit metadata as part of peer encode/decode
    DecodedPeer = libp2p_peer:decode(libp2p_peer:encode(MPeer)),
    ?assertEqual(Metadata, libp2p_peer:metadata(DecodedPeer)),

    ok.
