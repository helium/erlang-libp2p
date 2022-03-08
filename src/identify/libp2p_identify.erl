-module(libp2p_identify).

-include("pb/libp2p_peer_pb.hrl").
-include("pb/libp2p_identify_pb.hrl").


-type identify() :: #libp2p_signed_identify_pb{}.
-type identify_map() :: #{ peer => libp2p_peer:peer(),
                           observed_addr => string(),
                           nonce => binary()
                         }.
-export_type([identify/0, identify_map/0]).
-export([from_map/2, encode/1, decode/1, verify/1,
         pubkey_bin/1, peer/1, observed_maddr/1, observed_addr/1, nonce/1]).

-on_load(load_pb_msg_defs/0).

-spec from_map(identify_map(), libp2p_crypto:sig_fun()) -> identify().
from_map(Map, SigFun) ->
    Identify = #libp2p_identify_pb{peer=maps:get(peer, Map),
                                   observed_addr=multiaddr:new(maps:get(observed_addr, Map)),
                                   nonce=maps:get(nonce, Map)
                                  },
    Signature = SigFun(enif_protobuf:encode(Identify)),
    #libp2p_signed_identify_pb{identify=Identify, signature=Signature}.

-spec peer(identify()) -> libp2p_peer:peer().
peer(#libp2p_signed_identify_pb{identify=#libp2p_identify_pb{peer=Peer}}) ->
    Peer.

-spec pubkey_bin(identify()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(Identify=#libp2p_signed_identify_pb{}) ->
    libp2p_peer:pubkey_bin(peer(Identify)).

-spec observed_addr(identify()) -> string().
observed_addr(Identify=#libp2p_signed_identify_pb{}) ->
    multiaddr:to_string(observed_maddr(Identify)).

observed_maddr(#libp2p_signed_identify_pb{identify=#libp2p_identify_pb{observed_addr=ObservedAddr}}) ->
    ObservedAddr.

-spec nonce(identify()) -> string().
nonce(#libp2p_signed_identify_pb{identify=#libp2p_identify_pb{nonce=Nonce}}) ->
    Nonce.

%% @doc Encodes the given identify into its binary form.
-spec encode(identify()) -> binary().
encode(Msg=#libp2p_signed_identify_pb{}) ->
    enif_protobuf:encode(Msg).

%% @doc Decodes a given binary into an identify.
-spec decode(binary()) -> {ok, identify()} | {error, term()}.
decode(Bin) ->
    try
        Msg = enif_protobuf:decode(Bin, libp2p_signed_identify_pb),
        verify(Msg)
    catch
        _:_ -> {error, invalid_binary}
    end.

%% @doc Cryptographically verifies a given identify.
-spec verify(identify()) -> {ok, identify()} | {error, term()}.
verify(Msg=#libp2p_signed_identify_pb{identify=Ident=#libp2p_identify_pb{}, signature=Signature}) ->
    EncodedIdentify = enif_protobuf:encode(Ident),
    PubKey = libp2p_crypto:bin_to_pubkey(pubkey_bin(Msg)),
    case libp2p_crypto:verify(EncodedIdentify, Signature, PubKey) of
        true -> {ok, Msg};
        false -> {error, invalid_signature}
    end.

load_pb_msg_defs() ->
    ok = enif_protobuf:load_cache(libp2p_identify_pb:get_proto_defs()),
    enif_protobuf:set_opts([{string_as_list, true}]).
