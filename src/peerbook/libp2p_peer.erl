-module(libp2p_peer).

-include("pb/libp2p_peer_pb.hrl").

-type nat_type() :: libp2p_peer_pb:nat_type().
-type peer_map() :: #{ address => libp2p_crypto:address(),
                       listen_addrs => [string()],
                       connected => [binary()],
                       nat_type => nat_type()
                     }.
-type peer() :: #libp2p_signed_peer_pb{}.
-type association() :: #libp2p_association_pb{}.
-type metadata() :: [{string(), binary()}].
-export_type([peer/0, map/0, nat_type/0]).

-export([from_map/2, encode/1, decode/1, encode_list/1, decode_list/1, verify/1,
         address/1, listen_addrs/1, connected_peers/1, nat_type/1, timestamp/1,
         supersedes/2, is_stale/2, is_similar/2]).
%% associations
-export([associations/1, mk_association/3, association_verify/2,
         association_address/1, association_signature/1]).
%% metadata (unsigned!)
-export([metadata/1, metadata_set/2, metadata_put/3, metadata_get/3]).
%% blacklist (unsigned!)
-export([blacklist/1, is_blacklisted/2,
         blacklist_set/2, blacklist_add/2,
         cleared_listen_addrs/1]).

-spec from_map(peer_map(), fun((binary()) -> binary())) -> peer().
from_map(Map, SigFun) ->
    Timestamp = case maps:get(timestamp, Map, no_entry) of
                    no_entry -> erlang:system_time(millisecond);
                    V -> V
                end,
    %% NOTE: When you add fields to the peer definition ensure a
    %% corresponding update to is_similar/2
    Peer = #libp2p_peer_pb{address=maps:get(address, Map),
                           listen_addrs=[multiaddr:new(L) || L <- maps:get(listen_addrs, Map)],
                           connected = maps:get(connected, Map),
                           nat_type=maps:get(nat_type, Map),
                           timestamp=Timestamp,
                           associations=maps:get(associations, Map, [])},
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

%% @doc Gets the metadata map from the given peer. The metadata for a
%% peer is `NOT' part of the signed peer since it can be read and
%% updated by anyone to annotate the given peer with extra information
-spec metadata(peer()) -> metadata().
metadata(#libp2p_signed_peer_pb{metadata=Metadata}) ->
    Metadata.

%% @doc Replaces the full metadata for a given peer
-spec metadata_set(peer(), metadata()) -> peer().
metadata_set(Peer=#libp2p_signed_peer_pb{}, Metadata) when is_list(Metadata) ->
    Peer#libp2p_signed_peer_pb{metadata=Metadata}.

%% @doc Updates the metadata for a given peer with the given key/value
%% pair. The `Key' is expected to be a string, while `Value' is
%% expected to be a binary.
-spec metadata_put(peer(), string(), binary()) -> peer().
metadata_put(Peer=#libp2p_signed_peer_pb{}, Key, Value) when is_list(Key), is_binary(Value) ->
    Metadata = lists:keystore(Key, 1, metadata(Peer), {Key, Value}),
    metadata_set(Peer, Metadata).

%% @doc Gets the value for a stored `Key' in metadata. If not found,
%% the `Default' is returned.
-spec metadata_get(peer(), Key::string(), Default::binary()) -> binary().
metadata_get(Peer=#libp2p_signed_peer_pb{}, Key, Default) ->
    case lists:keyfind(Key, 1, metadata(Peer)) of
        false -> Default;
        {_, Value} -> Value
    end.

%% @doc Returns whether a given `Target' is more recent than `Other'
-spec supersedes(Target::peer(), Other::peer()) -> boolean().
supersedes(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=ThisTimestamp}},
           #libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=OtherTimestamp}}) ->
    ThisTimestamp > OtherTimestamp.

%% @doc Returns whether a given `Target` is mostly equal to an `Other`
%% peer. Similarity means equality for all fields, except for the
%% timestamp of the peers.
-spec is_similar(Target::peer(), Other::peer()) -> boolean().
is_similar(Target=#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{}},
           Other=#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{}}) ->
    address(Target) == address(Other)
        andalso nat_type(Target) == nat_type(Other)
        andalso sets:from_list(listen_addrs(Target)) == sets:from_list(listen_addrs(Other))
        andalso sets:from_list(connected_peers(Target)) == sets:from_list(connected_peers(Other))
        andalso sets:from_list(associations(Target)) == sets:from_list(associations(Other)).

%% @doc Returns whether a given peer is stale relative to a given
%% stale delta time in milliseconds.
-spec is_stale(peer(), integer()) -> boolean().
is_stale(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{timestamp=Timestamp}}, StaleMS) ->
    Now = erlang:system_time(millisecond),
    (Timestamp + StaleMS) < Now.

%% @doc Gets the blacklist for this peer. This is a metadata based
%% feature that enables listen addresses to be blacklisted so they
%% will not be connected to until that address is removed from the
%% blacklist.
-spec blacklist(peer()) -> [string()].
blacklist(#libp2p_signed_peer_pb{metadata=Metadata}) ->
    case lists:keyfind("blacklist", 1, Metadata) of
        false -> [];
        {_, Bin} -> binary_to_term(Bin)
    end.

%% @doc Returns whether a given address is blacklisted. Note that a
%% blacklisted address may not actually appear in the listen_addrs for
%% this peer.
-spec is_blacklisted(peer(), string()) -> boolean().
is_blacklisted(Peer=#libp2p_signed_peer_pb{}, ListenAddr) ->
   lists:member(ListenAddr, blacklist(Peer)).

%% @doc Sets the blacklist for a given peer. Note that currently no
%% validation is done against the existing listen addresses stored in
%% the peer. Blacklisting an address that the peer is not listening to
%% will have no effect anyway.
-spec blacklist_set(peer(), [string()]) -> peer().
blacklist_set(Peer=#libp2p_signed_peer_pb{}, BlackList) when is_list(BlackList) ->
    metadata_put(Peer, "blacklist", term_to_binary(BlackList)).

%% @doc Add a given listen address to the blacklist for the given
%% peer.
blacklist_add(Peer=#libp2p_signed_peer_pb{}, ListenAddr) ->
    BlackList = blacklist(Peer),
    NewBlackList = case lists:member(ListenAddr, BlackList) of
                       true -> BlackList;
                       false ->
                           [ListenAddr | BlackList]
                   end,
    blacklist_set(Peer, NewBlackList).

%% @doc Returns the listen addrs for this peer filtered using the
%% blacklist for the peer, if one is present. This is just a
%% convenience function to clear the listen adddresses for a peer
%% with the blacklist stored in metadata.
-spec cleared_listen_addrs(peer()) -> [string()].
cleared_listen_addrs(Peer=#libp2p_signed_peer_pb{}) ->
    sets:to_list(sets:subtract(sets:from_list(listen_addrs(Peer)),
                               sets:from_list(blacklist(Peer)))).

%% @doc Returns the associations for this peer. An association
%% associates a public key (crypto-address) with a signature of the
%% swarm address in the peer, using the private ke yof that public
%% keyof the swarm. This association proves that the given address has
%% control of the private associated with that given address.
-spec associations(peer()) -> [association()].
associations(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{associations=Assocs}}) ->
    Assocs.


%% @doc Make an association for a given peer address. The returned
%% association contains the given public key and the given peer
%% address signed with the passed in signature function.
-spec mk_association(PubKey::libp2p_crypto:address(),
                     PeerAddr::libp2p_crypto:address(),
                     SigFun::libp2p_crypto:sig_fun()) -> association().
mk_association(PubKey, PeerAddr, SigFun) ->
    #libp2p_association_pb{address=PubKey,
                           signature=SigFun(PeerAddr)
                          }.

-spec association_address(association()) -> libp2p_crypto:address().
association_address(#libp2p_association_pb{address=Address}) ->
    Address.

-spec association_signature(association()) -> binary().
association_signature(#libp2p_association_pb{signature=Signature}) ->
    Signature.

-spec association_verify(association(), peer()) -> boolean().
association_verify(Assoc=#libp2p_association_pb{}, Peer=#libp2p_signed_peer_pb{}) ->
    PubKey = libp2p_crypto:address_to_pubkey(association_address(Assoc)),
    Data = address(Peer),
    case public_key:verify(Data, sha256, association_signature(Assoc), PubKey) of
        true -> true;
        false -> error(invalid_association_signature)
    end.

%% @doc Encodes the given peer into its binary form.
-spec encode(peer()) -> binary().
encode(Msg=#libp2p_signed_peer_pb{}) ->
    libp2p_peer_pb:encode_msg(Msg).

%% @doc Encodes a given list of peer into a binary form. Since
%% encoding lists is primarily used for gossipping peers around, this
%% strips metadata from the peers as part of encoding.
-spec encode_list([peer()]) -> binary().
encode_list(List) ->
    StrippedList = [metadata_set(P, []) || P <- List],
    libp2p_peer_pb:encode_msg(#libp2p_peer_list_pb{peers=StrippedList}).

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
        true ->
            lists:all(fun(Assoc) ->
                              association_verify(Assoc, Msg)
                      end, associations(Msg)),
            Msg;
        false -> error(invalid_signature)
    end.
