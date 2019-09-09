%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Identify ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_identify).

-include("pb/libp2p_peer_pb.hrl").
-include("pb/libp2p_identify_pb.hrl").

-export([from_map/2, encode/1, decode/1, verify/1,
         pubkey_bin/1, peer/1, observed_maddr/1, observed_addr/1, nonce/1]).


-type signed_identify() :: #libp2p_signed_identify_pb{identify :: libp2p_identify:identify() | undefined,
                                                      signature :: iodata() | undefined}.
-type identify() :: #libp2p_identify_pb{peer :: libp2p_identify:signed_identify() | undefined,
                                        observed_addr :: iodata() | undefined,
                                        nonce :: iodata() | undefined}.
-type identify_map() :: #{ peer => libp2p_peer:peer(),
                           observed_addr => string(),
                           nonce => binary()
                         }.
-export_type([identify/0, identify_map/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an identify from map
%% @end
%%--------------------------------------------------------------------
-spec from_map(identify_map(), libp2p_crypto:sig_fun()) -> identify().
from_map(Map, SigFun) ->
    Identify = #libp2p_identify_pb{peer=maps:get(peer, Map),
                                   observed_addr=multiaddr:new(maps:get(observed_addr, Map)),
                                   nonce=maps:get(nonce, Map)
                                  },
    Signature = SigFun(libp2p_identify_pb:encode_msg(Identify)),
    #libp2p_signed_identify_pb{identify=Identify, signature=Signature}.

%%--------------------------------------------------------------------
%% @doc
%% Get peer
%% @end
%%--------------------------------------------------------------------
-spec peer(identify()) -> libp2p_peer:peer().
peer(#libp2p_signed_identify_pb{identify=#libp2p_identify_pb{peer=Peer}}) ->
    Peer.

%%--------------------------------------------------------------------
%% @doc
%% Get pubkey bin
%% @end
%%--------------------------------------------------------------------
-spec pubkey_bin(identify()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(Identify=#libp2p_signed_identify_pb{}) ->
    libp2p_peer:pubkey_bin(peer(Identify)).

%%--------------------------------------------------------------------
%% @doc
%% Get observed address
%% @end
%%--------------------------------------------------------------------
-spec observed_addr(identify()) -> string().
observed_addr(Identify=#libp2p_signed_identify_pb{}) ->
    multiaddr:to_string(observed_maddr(Identify)).

-spec observed_maddr(identify()) -> string().
observed_maddr(#libp2p_signed_identify_pb{identify=#libp2p_identify_pb{observed_addr=ObservedAddr}}) ->
    ObservedAddr.

%%--------------------------------------------------------------------
%% @doc
%% Get nonce
%% @end
%%--------------------------------------------------------------------
-spec nonce(identify()) -> string().
nonce(#libp2p_signed_identify_pb{identify=#libp2p_identify_pb{nonce=Nonce}}) ->
    Nonce.

%%--------------------------------------------------------------------
%% @doc
%% Encodes the given identify into its binary form.
%% @end
%%--------------------------------------------------------------------
-spec encode(identify()) -> binary().
encode(Msg=#libp2p_signed_identify_pb{}) ->
    libp2p_identify_pb:encode_msg(Msg).

%%--------------------------------------------------------------------
%% @doc
%% Decodes a given binary into an identify.
%% @end
%%--------------------------------------------------------------------
-spec decode(binary()) -> {ok, identify()} | {error, term()}.
decode(Bin) ->
    try
        Msg = libp2p_identify_pb:decode_msg(Bin, libp2p_signed_identify_pb),
        verify(Msg)
    catch
        _:_ -> {error, invalid_binary}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Cryptographically verifies a given identify.
%% @end
%%--------------------------------------------------------------------
-spec verify(identify()) -> {ok, identify()} | {error, term()}.
verify(Msg=#libp2p_signed_identify_pb{identify=Ident=#libp2p_identify_pb{}, signature=Signature}) ->
    EncodedIdentify = libp2p_identify_pb:encode_msg(Ident),
    PubKey = libp2p_crypto:bin_to_pubkey(pubkey_bin(Msg)),
    case libp2p_crypto:verify(EncodedIdentify, Signature, PubKey) of
        true -> {ok, Msg};
        false -> {error, invalid_signature}
    end.
