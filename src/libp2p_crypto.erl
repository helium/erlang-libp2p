-module(libp2p_crypto).

-include_lib("public_key/include/public_key.hrl").

-type private_key() :: #'ECPrivateKey'{}.
-type public_key() :: {#'ECPoint'{}, {namedCurve, ?secp256r1}}.
-type address() :: ecc_compact:compact_key().
-type sig_fun() :: fun((binary()) -> binary()).

-export_type([private_key/0, public_key/0, address/0, sig_fun/0]).

-export([generate_keys/0, mk_sig_fun/1, load_keys/1, save_keys/2,
         pubkey_to_address/1, address_to_pubkey/1,
         address_to_b58/1, b58_to_address/1,
         pubkey_to_b58/1, b58_to_pubkey/1, verify/3
        ]).

-spec make_public_key(private_key()) -> public_key().
make_public_key(#'ECPrivateKey'{parameters=Params, publicKey=PubKey}) ->
    {#'ECPoint'{point=PubKey}, Params}.

%% @doc Generate keys suitable for a swarm.  The returned private and
%% public key has the attribute that the public key is a compressable
%% public key.
-spec generate_keys() -> {private_key(), public_key()}.
generate_keys() ->
    {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
    PubKey = ecc_compact:recover_key(CompactKey),
    {PrivKey, PubKey}.

%% @doc Load the private key from a pem encoded given filename.
%% Returns the private and extracted public key stored in the file or
%% an error if any occorred.
-spec load_keys(string()) -> {ok, private_key(), public_key()} | {error, term()}.
load_keys(FileName) ->
    case file:read_file(FileName) of
        {ok, PemBin} ->
            [PemEntry] = public_key:pem_decode(PemBin),
            PrivKey = public_key:pem_entry_decode(PemEntry),
            PubKey = make_public_key(PrivKey),
            {ok, PrivKey, PubKey};
        {error, Error} -> {error, Error}
    end.

-spec mk_sig_fun(private_key()) -> sig_fun().
mk_sig_fun(PrivKey) ->
    fun(Bin) -> public_key:sign(Bin, sha256, PrivKey) end.

%% @doc Store the given keys in a file.  See @see key_folder/1 for a
%% utility function that returns a name and location for the keys that
%% are relative to the swarm data folder.
-spec save_keys({private_key(), public_key()}, string()) -> ok | {error, term()}.
save_keys({PrivKey, _PubKey}, FileName) when is_list(FileName) ->
    PemEntry = public_key:pem_entry_encode('ECPrivateKey', PrivKey),
    PemBin = public_key:pem_encode([PemEntry]),
    file:write_file(FileName, PemBin).

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

%% @doc Verifies a digital signature, using sha256.
-spec verify(binary(), binary(), public_key()) -> boolean().
verify(Bin, Signature, PubKey) ->
    public_key:verify(Bin, sha256, Signature, PubKey).

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


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

generate_full_key() ->
    PrivKey = #'ECPrivateKey'{parameters=Params, publicKey=PubKeyPoint} =
        public_key:pem_entry_decode(lists:nth(2, public_key:pem_decode(list_to_binary(os:cmd("openssl ecparam -name prime256v1 -genkey -outform PEM"))))),
    PubKey = {#'ECPoint'{point=PubKeyPoint}, Params},
    case ecc_compact:is_compact(PubKey) of
        {true, _} -> generate_full_key();
        false -> {PrivKey, PubKey}
    end.

save_load_test() ->
    FileName = test_util:nonl(os:cmd("mktemp")),
    Keys = {PrivKey, PubKey} = generate_keys(),
    ok = libp2p_crypto:save_keys(Keys, FileName),
    {ok, LPrivKey, LPubKey} = load_keys(FileName),
    {PrivKey, PubKey} = {LPrivKey, LPubKey},
    {error, _} = load_keys(FileName ++ "no"),
    ok.

address_test() ->
    {_PrivKey, PubKey} = generate_keys(),

    Address = pubkey_to_address(PubKey),
    B58Address = address_to_b58(Address),

    B58Address = pubkey_to_b58(PubKey),
    PubKey = b58_to_pubkey(B58Address),

    {'EXIT', {bad_checksum, _}} = (catch b58_to_address(B58Address ++ "bad")),

    {_, FullKey} = generate_full_key(),
    {'EXIT', {not_compact, _}} = (catch pubkey_to_address(FullKey)),
    ok.

verify_test() ->
    {PrivKey, PubKey} = generate_keys(),

    Bin = <<"sign me please">>,
    Sign = mk_sig_fun(PrivKey),
    Signature = Sign(Bin),

    true = verify(Bin, Signature, PubKey),
    false = verify(<<"failed...">>, Signature, PubKey).


-endif.
