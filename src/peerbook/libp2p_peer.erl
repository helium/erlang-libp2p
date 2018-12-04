-module(libp2p_peer).

-include("pb/libp2p_peer_pb.hrl").

-type nat_type() :: libp2p_peer_pb:nat_type().
-type peer_map() :: #{ address => libp2p_crypto:address(),
                       listen_addrs => [string()],
                       connected => [binary()],
                       nat_type => nat_type(),
                       associations => association_map()
                     }.
-type peer() :: #libp2p_signed_peer_pb{}.
-type association() :: #libp2p_association_pb{}.
-type association_map() :: [{Type::string(), [association()]}].
-type metadata() :: [{string(), binary()}].
-export_type([peer/0, association/0, peer_map/0, nat_type/0]).

-export([from_map/2, encode/1, decode/1, encode_list/1, decode_list/1, verify/1,
         address/1, listen_addrs/1, connected_peers/1, nat_type/1, timestamp/1,
         supersedes/2, is_stale/2, is_similar/2]).
%% associations
-export([associations/1, association_addrs/1, associations_set/4, associations_get/2, associations_put/4,
         is_association/3, association_address/1, association_signature/1,
         mk_association/3, association_verify/2,
         association_encode/1, association_decode/2]).
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
    Assocs = lists:map(fun({Type, AssocEntries}) ->
                               {Type, #libp2p_association_list_pb{associations=AssocEntries}}
                       end, maps:get(associations, Map, [])),
    Peer = #libp2p_peer_pb{address=maps:get(address, Map),
                           listen_addrs=[multiaddr:new(L) || L <- maps:get(listen_addrs, Map)],
                           connected = maps:get(connected, Map),
                           nat_type=maps:get(nat_type, Map),
                           timestamp=Timestamp,
                           associations=Assocs
                          },
    sign_peer(Peer, SigFun).

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

%% @doc Get the associations for this peer. This returns a keyed list
%% with the association type as the key and a list of assocations as
%% the value for that type.
-spec associations(peer()) -> association_map().
associations(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{associations=Assocs}}) ->
    lists:map(fun({AssocType, #libp2p_association_list_pb{associations=AssocEntries}}) ->
                      {AssocType, AssocEntries}
              end, Assocs).

%% @doc Returns a list of association addresses. This can be used, for example, to
%% compare to peer assocation records with eachother (like in is_similar/2)
-spec association_addrs(peer()) -> [{AssocType::string(), [AssocAddr::libp2p_crypto:address()]}].
association_addrs(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{associations=Assocs}}) ->
    lists:map(fun({AssocType, #libp2p_association_list_pb{associations=AssocEntries}}) ->
                      {AssocType, [association_address(A) || A <- AssocEntries]}
              end, Assocs).

%% @doc Replaces all associations for a given association type in the
%% given peer.
-spec associations_set(peer(), AssocType::string(), [association()], PeerSigFun::libp2p_crypto:sig_fun())
                      -> peer().
associations_set(#libp2p_signed_peer_pb{peer=Peer=#libp2p_peer_pb{associations=Assocs}},
                 AssocType, NewAssocs, PeerSigFun) ->
    ListifiedAssocs = #libp2p_association_list_pb{associations=NewAssocs},
    UpdatedAssocs = lists:keystore(AssocType, 1, Assocs, {AssocType, ListifiedAssocs}),
    UpdatedPeer = Peer#libp2p_peer_pb{associations=UpdatedAssocs},
    sign_peer(UpdatedPeer, PeerSigFun).

%% @doc Gets the associations of the given `AssocType' for the given peer.
-spec associations_get(peer(), string()) -> [association()].
associations_get(#libp2p_signed_peer_pb{peer=#libp2p_peer_pb{associations=Assocs}}, AssocType) ->
    case lists:keyfind(AssocType, 1, Assocs) of
        false -> [];
        {_, #libp2p_association_list_pb{associations=AssocEntries}} -> AssocEntries
    end.

%% @doc Adds or replaces a given assocation for the given type to the
%% peer. The returned peer is signed with the provided signing
%% function.
-spec associations_put(peer(), AssocType::string(), association(), PeerSigFun::libp2p_crypto:sig_fun())
                      -> peer().
associations_put(Peer=#libp2p_signed_peer_pb{}, AssocType, Assoc, PeerSigFun) ->
    %% Get current associations for type
    CurrentAssocs = associations_get(Peer, AssocType),
    %% Store the new association, replacing an existing one if there.
    UpdatedAssocs = lists:keystore(association_address(Assoc),
                                   #libp2p_association_pb.address,
                                   CurrentAssocs,
                                   Assoc),
    %% and set the associations for the same type
    associations_set(Peer, AssocType, UpdatedAssocs, PeerSigFun).


%% @doc Checks whether a given peer has an association stored with the
%% given assocation type and address
-spec is_association(peer(), AssocType::string(), AssocAddress::libp2p_crypto:address()) -> boolean().
is_association(Peer=#libp2p_signed_peer_pb{}, AssocType, AssocAddr) ->
    Assocs = associations_get(Peer, AssocType),
    case lists:keyfind(AssocAddr, #libp2p_association_pb.address, Assocs) of
        false -> false;
        _ -> true
    end.

%% @doc Make an association for a given peer address. The returned
%% association contains the given assocation address and the given
%% peer address signed with the passed in association provided
%% signature function.
-spec mk_association(AssocAddr::libp2p_crypto:address(),
                     PeerAddr::libp2p_crypto:address(),
                     AssocSigFun::libp2p_crypto:sig_fun()) -> association().
mk_association(AssocAddr, PeerAddr, AssocSigFun) ->
    #libp2p_association_pb{ address=AssocAddr,
                            signature=AssocSigFun(PeerAddr)
                          }.

%% @doc Gets the address for the given association
-spec association_address(association()) -> libp2p_crypto:address().
association_address(#libp2p_association_pb{address=Address}) ->
    Address.

%% @doc Gets the signature for the given association
-spec association_signature(association()) -> binary().
association_signature(#libp2p_association_pb{signature=Signature}) ->
    Signature.

%% @doc Returns true if the association can be verified against the
%% given peer address. This has to be the same peer address that was
%% used to construct the signature in the assocation and should be the
%% address of the peer record containing the given association.
-spec association_verify(association(), PeerAddr::libp2p_crypto:address()) -> true.
association_verify(Assoc=#libp2p_association_pb{}, Address) ->
    PubKey = libp2p_crypto:address_to_pubkey(association_address(Assoc)),
    case public_key:verify(Address, sha256, association_signature(Assoc), PubKey) of
        true -> true;
        false -> error(invalid_association_signature)
    end.

%% @doc Encodes the given association to it's binary form
-spec association_encode(association()) -> binary().
association_encode(Msg=#libp2p_association_pb{}) ->
    libp2p_peer_pb:encode_msg(Msg).

%% @doc Decodes the given binary to an association and verifies it
%% against the given peer address.
-spec association_decode(binary(), PeerAddr::libp2p_crypto:address()) -> binary().
association_decode(Bin, PeerAddr) ->
    Msg = libp2p_peer_pb:decode_msg(Bin, libp2p_association_pb),
    true = association_verify(Msg,PeerAddr),
    Msg.

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
        %% We only comparet the {type, assoc_adddress} parts of an
        %% association as multiple signatures over the same value will
        %% differ
        andalso sets:from_list(association_addrs(Target)) == sets:from_list(association_addrs(Other)).

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
    true = verify(Msg),
    Msg.


%% @doc Cryptographically verifies a given peer and it's
%% associations. Returns trus if the given peer can be verified or
%% throws an error if the peer or one of it's associations can't be
%% verified
-spec verify(peer()) -> true.
verify(Msg=#libp2p_signed_peer_pb{peer=Peer=#libp2p_peer_pb{associations=Assocs}, signature=Signature}) ->
    EncodedPeer = libp2p_peer_pb:encode_msg(Peer),
    PubKey = libp2p_crypto:address_to_pubkey(address(Msg)),
    case public_key:verify(EncodedPeer, sha256, Signature, PubKey) of
        true ->
            lists:all(fun({_AssocType, #libp2p_association_list_pb{associations=AssocEntries}}) ->
                              MsgAddress = address(Msg),
                              lists:all(fun(Assoc) ->
                                                association_verify(Assoc, MsgAddress)
                                        end, AssocEntries)
                      end, Assocs);
        false -> error(invalid_signature)
    end.

%%
%% Internal
%%

-spec sign_peer(#libp2p_peer_pb{}, libp2p_crypto:sig_fun()) -> peer().
sign_peer(Peer, SigFun) ->
    EncodedPeer = libp2p_peer_pb:encode_msg(Peer),
    Signature = SigFun(EncodedPeer),
    #libp2p_signed_peer_pb{peer=Peer, signature=Signature}.
