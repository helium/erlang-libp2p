-module(libp2p_peer).

-include("pb/libp2p_peer_pb.hrl").

-type nat_type() :: libp2p_peer_pb:nat_type().
-type peer_map() :: #{ address => libp2p_crypto:address(),
                       listen_addrs => [string()],
                       connected => [binary()],
                       nat_type => nat_type()
                     }.
-type peer() :: #libp2p_signed_peer_pb{}.
-type metadata() :: [{string(), binary()}].
-export_type([peer/0, map/0, nat_type/0]).

-export([from_map/2, encode/1, decode/1, encode_list/1, decode_list/1, verify/1,
         address/1, listen_addrs/1, connected_peers/1, nat_type/1, timestamp/1,
         supersedes/2, is_stale/2, is_similar/2]).
%% metadata
-export([metadata/1, set_metadata/2]).

-spec from_map(peer_map(), fun((binary()) -> binary())) -> peer().
from_map(Map, SigFun) ->
    Timestamp = case maps:get(timestamp, Map, no_entry) of
                    no_entry -> erlang:system_time(millisecond);
                    V -> V
                end,
    Peer = #libp2p_peer_pb{address=maps:get(address, Map),
                           listen_addrs=[multiaddr:new(L) || L <- maps:get(listen_addrs, Map)],
                           connected = maps:get(connected, Map),
                           nat_type=maps:get(nat_type, Map),
                           timestamp=Timestamp},
    EncodedPeer = libp2p_peer_pb:encode_msg(Peer),
    Signature = SigFun(EncodedPeer),
    #libp2p_signed_peer_pb{peer=Peer, signature=Signature}.

%% @doc Gets the crypto address for the given peer.
-spec address(peer()) -> libp2p_crypto:address().
address(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{address=Addr}}) ->
    Addr.

%% @doc Gets the list of peer multiaddrs that the given peer is
%% listening on.
-spec listen_addrs(peer()) -> [string()].
listen_addrs(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{listen_addrs=Addrs}}) ->
    [multiaddr:to_string(A) || A <- Addrs].

%% @doc Gets the list of peer crypto addresses that the given peer was last
%% known to be connected to.
-spec connected_peers(peer()) -> [binary()].
connected_peers(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{connected=Conns}}) ->
    Conns.

%% @doc Gets the NAT type of the given peer.
-spec nat_type(peer()) -> nat_type().
nat_type(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{nat_type=NatType}}) ->
    NatType.

%% @doc Gets the timestamp of the given peer.
-spec timestamp(peer()) -> integer().
timestamp(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=Timestamp}}) ->
    Timestamp.

%% @doc Gets the metadata map from the given peer. The metadat for a
%% peer is `NOT' part of the signed peer since it can be read and
%% updated by anyone to annotate the given peer with extra information
-spec metadata(peer()) -> metadata().
metadata(#libp2p_signed_peer_pb{metadata=Metadata}) ->
    Metadata.

-spec set_metadata(peer(), metadata()) -> peer().
set_metadata(Peer=#libp2p_signed_peer_pb{}, Metadata) when is_list(Metadata) ->
    Peer#libp2p_signed_peer_pb{metadata=Metadata}.

%% @doc Returns whether a given `Target' is more recent than `Other'
-spec supersedes(Target::peer(), Other::peer()) -> boolean().
supersedes(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=ThisTimestamp}},
           #libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=OtherTimestamp}}) ->
    ThisTimestamp > OtherTimestamp.

%% @doc Returns whether a given `Target` is mostly equal to an `Other`
%% peer. Similarity means equality foro all fields, except for the
%% timestamp of the peers.
-spec is_similar(Target::peer(), Other::peer()) -> boolean().
is_similar(Target=#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{}},
           Other=#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{}}) ->
    address(Target) == address(Other)
        andalso nat_type(Target) == nat_type(Other)
        andalso sets:from_list(listen_addrs(Target)) == sets:from_list(listen_addrs(Other))
        andalso sets:from_list(connected_peers(Target)) == sets:from_list(connected_peers(Other)).

%% @doc Returns whether a given peer is stale relative to a given
%% stale delta time in milliseconds.
-spec is_stale(peer(), integer()) -> boolean().
is_stale(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=Timestamp}}, StaleMS) ->
    Now = erlang:system_time(millisecond),
    (Timestamp + StaleMS) < Now.

%% @doc Encodes the given peer into its binary form.
-spec encode(peer()) -> binary().
encode(Msg=#libp2p_signed_peer_pb{}) ->
    libp2p_peer_pb:encode_msg(Msg).

%% @doc Encodes a given list of peer into a binary form.
-spec encode_list([peer()]) -> binary().
encode_list(List) ->
    libp2p_peer_pb:encode_msg(#libp2p_peer_list_pb{peers=List}).

%% @doc Decodes a given binary into a list of peers.
-spec decode_list(binary()) -> [peer()].
decode_list(Bin) ->
    List = libp2p_peer_pb:decode_msg(Bin, libp2p_peer_list_pb),
    List#libp2p_peer_list_pb.peers.

%% @doc Decodes a given binary into a peer.
-spec decode(binary()) -> peer().
decode(Bin) ->
    Msg = libp2p_peer_pb:decode_msg(Bin, libp2p_signed_peer_pb),
    verify(Msg).

%% @doc Cryptographically verifies a given peer.
-spec verify(peer()) -> peer().
verify(Msg=#libp2p_signed_peer_pb{peer=Peer=#libp2p_peer_pb{}, signature=Signature}) ->
    EncodedPeer = libp2p_peer_pb:encode_msg(Peer),
    PubKey = libp2p_crypto:address_to_pubkey(Peer#libp2p_peer_pb.address),
    case public_key:verify(EncodedPeer, sha256, Signature, PubKey) of
        true -> Msg;
        false -> error(invalid_signature)
    end.
