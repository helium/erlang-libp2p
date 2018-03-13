-module(libp2p_crypto).

-include_lib("public_key/include/public_key.hrl").

-type private_key() :: #'ECPrivateKey'{}.
-type public_key() :: {#'ECPoint'{}, {namedCurve, ?secp256r1}}.
-type address() :: ecc_compact:compact_key().

-export_type([private_key/0, public_key/0, address/0]).

-export([swarm_keys/1,
         pubkey_to_address/1, address_to_pubkey/1,
         address_to_b58/1, b58_to_address/1,
         pubkey_to_b58/1, b58_to_pubkey/1
        ]).

-spec make_public_key(private_key()) -> public_key().
make_public_key(#'ECPrivateKey'{parameters=Params, publicKey=PubKey}) ->
    {#'ECPoint'{point=PubKey}, Params}.

-spec swarm_keys(ets:tab() | string()) -> {private_key(), public_key()}.
swarm_keys(FileName) when is_list(FileName) ->
    case file:read_file(FileName) of
        {ok, PemBin} ->
            [PemEntry] = public_key:pem_decode(PemBin),
            PrivKey = public_key:pem_entry_decode(PemEntry),
            PubKey = make_public_key(PrivKey),
            {PrivKey, PubKey};
        {error, enoent} ->
            {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
            PubKey = ecc_compact:recover_key(CompactKey),
            PemEntry = public_key:pem_entry_encode('ECPrivateKey', PrivKey),
            PemBin = public_key:pem_encode([PemEntry]),
            case file:write_file(FileName, PemBin) of
                ok -> {PrivKey, PubKey};
                {error, Error} -> error(Error)
            end
    end;
swarm_keys(TID) ->
    Name = libp2p_swarm:name(TID),
    FileName = libp2p_config:data_dir(TID, atom_to_list(Name) ++ ".pem"),
    swarm_keys(FileName).


-spec pubkey_to_address(public_key() | ecc_compact:compact_key()) -> address().
pubkey_to_address(PubKey) ->
    case ecc_compact:is_compact(PubKey) of
        {true, CompactKey} -> CompactKey;
        false -> erlang:error(not_compact)
    end.

-spec address_to_pubkey(address()) -> public_key().
address_to_pubkey(Addr) ->
    ecc_compact:recover_key(Addr).

-spec pubkey_to_b58(public_key() | ecc_compact:compact_key()) -> string().
pubkey_to_b58(PubKey) ->
    address_to_b58(pubkey_to_address(PubKey)).

-spec b58_to_pubkey(string()) -> public_key().
b58_to_pubkey(Str) ->
    address_to_pubkey(b58_to_address(Str)).

-spec address_to_b58(address()) -> string().
address_to_b58(Addr) ->
    base58check_encode(<<16#00>>, Addr).

-spec b58_to_address(string())-> address().
b58_to_address(Str) ->
    case base58check_decode(Str) of
        {ok, <<16#00>>, Addr} -> Addr;
        {error, Reason} -> error(Reason)
    end.

-spec base58check_encode(binary(), binary()) -> string().
base58check_encode(Version, Payload) ->
  VPayload = <<Version/binary, Payload/binary>>,
  <<Checksum:4/binary, _/binary>> = crypto:hash(sha256, crypto:hash(sha256, VPayload)),
  Result = <<VPayload/binary, Checksum/binary>>,
  base58:binary_to_base58(Result).

-spec base58check_decode(string()) -> {'ok',<<_:8>>,binary()} | {error,bad_checksum}.
base58check_decode(B58) ->
  Bin = base58:base58_to_binary(B58),
  PayloadSize = byte_size(Bin) - 5,
  <<Version:1/binary, Payload:PayloadSize/binary, Checksum:4/binary>> = Bin,
  %% validate the checksum
  case crypto:hash(sha256, crypto:hash(sha256, <<Version/binary, Payload/binary>>)) of
    <<Checksum:4/binary, _/binary>> ->
      {ok, Version, Payload};
    _ ->
      {error, bad_checksum}
  end.
