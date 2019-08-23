%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Crypto ==
%% Crypto utils
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_crypto).

-include_lib("public_key/include/public_key.hrl").

-define(KEYTYPE_ECC_COMPACT, 0).
-define(KEYTYPE_ED25519,     1).

-type key_type() ::
        ecc_compact |
        ed25519.
-type privkey() ::
        {ecc_compact, ecc_compact:private_key()} |
        {ed25519, enacl_privkey()}.
-type pubkey() ::
        {ecc_compact, ecc_compact:public_key()} |
        {ed25519, enacl_pubkey()}.
-type pubkey_bin() :: <<_:8, _:_*8>>.
-type sig_fun() :: fun((binary()) -> binary()).
-type ecdh_fun() :: fun((pubkey()) -> binary()).
-type key_map() :: #{ secret => privkey(), public => pubkey()}.
-type enacl_privkey() :: <<_:256>>.
-type enacl_pubkey() :: <<_:256>>.

-export_type([privkey/0, pubkey/0, pubkey_bin/0, sig_fun/0, ecdh_fun/0]).

-export([generate_keys/1, mk_sig_fun/1, mk_ecdh_fun/1,
         load_keys/1, save_keys/2,
         pubkey_to_bin/1, bin_to_pubkey/1,
         bin_to_b58/1, bin_to_b58/2,
         b58_to_bin/1, b58_to_version_bin/1,
         pubkey_to_b58/1, b58_to_pubkey/1,
         pubkey_bin_to_p2p/1, p2p_to_pubkey_bin/1,
         verify/3,
         keys_to_bin/1, keys_from_bin/1
        ]).

%%--------------------------------------------------------------------
%% @doc
%% Generate keys suitable for a swarm. The returned private and
%% public key has the attribute that the public key is a compressable
%% public key.
%% @end
%%--------------------------------------------------------------------
-spec generate_keys(key_type()) -> key_map().
generate_keys(ecc_compact) ->
    {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
    PubKey = ecc_compact:recover_key(CompactKey),
    #{secret => {ecc_compact, PrivKey}, public => {ecc_compact, PubKey}};
generate_keys(ed25519) ->
    #{public := PubKey, secret := PrivKey} = enacl:crypto_sign_ed25519_keypair(),
    #{secret => {ed25519, PrivKey}, public => {ed25519, PubKey}}.

%%--------------------------------------------------------------------
%% @doc
%% Load the private key from a pem encoded given filename.
%% Returns the private and extracted public key stored in the file or
%% an error if any occorred.
%% @end
%%--------------------------------------------------------------------
-spec load_keys(string()) -> {ok, key_map()} | {error, term()}.
load_keys(FileName) ->
    case file:read_file(FileName) of
        {ok, Bin} -> {ok, keys_from_bin(Bin)};
        {error, Error} -> {error, Error}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Create signature function from private key
%% @end
%%--------------------------------------------------------------------
-spec mk_sig_fun(privkey()) -> sig_fun().
mk_sig_fun({ecc_compact, PrivKey}) ->
    fun(Bin) -> public_key:sign(Bin, sha256, PrivKey) end;
mk_sig_fun({ed25519, PrivKey}) ->
    fun(Bin) -> enacl:sign_detached(Bin, PrivKey) end.

%%--------------------------------------------------------------------
%% @doc
%% Create ecdh signature function from private key.
%% Note that a Key Derivation Function should be applied to these keys before use
%% @end
%%--------------------------------------------------------------------
-spec mk_ecdh_fun(privkey()) -> ecdh_fun().
mk_ecdh_fun({ecc_compact, PrivKey}) ->
    fun({ecc_compact, {PubKey, {namedCurve, ?secp256r1}}}) -> public_key:compute_key(PubKey, PrivKey) end;
mk_ecdh_fun({ed25519, PrivKey}) ->
    %% Do an X25519 ECDH exchange after converting the ED25519 keys to Curve25519 keys
    fun({ed25519, PubKey}) -> enacl:box_beforenm(enacl:crypto_sign_ed25519_public_to_curve25519(PubKey),
                                                 enacl:crypto_sign_ed25519_secret_to_curve25519(PrivKey)) end.


%%--------------------------------------------------------------------
%% @doc
%% Store the given keys in a file.  See @see key_folder/1 for a
%% utility function that returns a name and location for the keys that
%% are relative to the swarm data folder.
%% @end
%%--------------------------------------------------------------------
-spec save_keys(key_map(), string()) -> ok | {error, term()}.
save_keys(KeysMap, FileName) when is_list(FileName) ->
    Bin = keys_to_bin(KeysMap),
    file:write_file(FileName, Bin).

%%--------------------------------------------------------------------
%% @doc
%% Compact keys to a binary
%% @end
%%--------------------------------------------------------------------
-spec keys_to_bin(key_map()) -> binary().
keys_to_bin(#{secret := {ecc_compact, PrivKey}, public := {ecc_compact, _PubKey}}) ->
    #'ECPrivateKey'{privateKey=PrivKeyBin, publicKey=PubKeyBin} = PrivKey,
    case byte_size(PrivKeyBin) of
        32 ->
            <<?KEYTYPE_ECC_COMPACT:8, PrivKeyBin:32/binary, PubKeyBin/binary>>;
        31 ->
            %% sometimes a key is only 31 bytes
            <<?KEYTYPE_ECC_COMPACT:8, 0:8/integer, PrivKeyBin:31/binary, PubKeyBin/binary>>
    end;
keys_to_bin(#{secret := {ed25519, PrivKey}, public := {ed25519, PubKey}}) ->
    <<?KEYTYPE_ED25519:8, PrivKey:64/binary, PubKey:32/binary>>.

%%--------------------------------------------------------------------
%% @doc
%% Unpack keys from binary
%% @end
%%--------------------------------------------------------------------
-spec keys_from_bin(binary()) -> key_map().
keys_from_bin(<<?KEYTYPE_ECC_COMPACT:8, 0:8/integer, PrivKeyBin:31/binary, PubKeyBin/binary>>) ->
    Params = {namedCurve, ?secp256r1},
    PrivKey = #'ECPrivateKey'{version=1, parameters=Params, privateKey=PrivKeyBin, publicKey=PubKeyBin},
    PubKey = {#'ECPoint'{point=PubKeyBin}, Params},
    #{secret => {ecc_compact, PrivKey}, public => {ecc_compact, PubKey}};
keys_from_bin(<<?KEYTYPE_ECC_COMPACT:8, PrivKeyBin:32/binary, PubKeyBin/binary>>) ->
    Params = {namedCurve, ?secp256r1},
    PrivKey = #'ECPrivateKey'{version=1, parameters=Params, privateKey=PrivKeyBin, publicKey=PubKeyBin},
    PubKey = {#'ECPoint'{point=PubKeyBin}, Params},
    #{secret => {ecc_compact, PrivKey}, public => {ecc_compact, PubKey}};
keys_from_bin(<<?KEYTYPE_ED25519, PrivKey:64/binary, PubKey:32/binary>>) ->
    #{secret => {ed25519, PrivKey}, public => {ed25519, PubKey}}.

%%--------------------------------------------------------------------
%% @doc
%% Compact public key to binary
%% @end
%%--------------------------------------------------------------------
-spec pubkey_to_bin(pubkey()) -> pubkey_bin().
pubkey_to_bin({ecc_compact, PubKey}) ->
    case ecc_compact:is_compact(PubKey) of
        {true, CompactKey} -> <<?KEYTYPE_ECC_COMPACT, CompactKey/binary>>;
        false -> erlang:error(not_compact)
    end;
pubkey_to_bin({ed25519, PubKey}) ->
    <<?KEYTYPE_ED25519, PubKey/binary>>.

%%--------------------------------------------------------------------
%% @doc
%% Unpack public key from binary
%% @end
%%--------------------------------------------------------------------
-spec bin_to_pubkey(pubkey_bin()) -> pubkey().
bin_to_pubkey(<<?KEYTYPE_ECC_COMPACT, PubKey:32/binary>>) ->
    {ecc_compact, ecc_compact:recover_key(PubKey)};
bin_to_pubkey(<<?KEYTYPE_ED25519, PubKey:32/binary>>) ->
    {ed25519, PubKey}.

%%--------------------------------------------------------------------
%% @doc
%% Compact public key to b58 (string)
%% @end
%%--------------------------------------------------------------------
-spec pubkey_to_b58(pubkey()) -> string().
pubkey_to_b58(PubKey) ->
    bin_to_b58(pubkey_to_bin(PubKey)).

%%--------------------------------------------------------------------
%% @doc
%% Unpack public key from b58
%% @end
%%--------------------------------------------------------------------
-spec b58_to_pubkey(string()) -> pubkey().
b58_to_pubkey(Str) ->
    bin_to_pubkey(b58_to_bin(Str)).

%%--------------------------------------------------------------------
%% @doc
%% Verifies a digital signature, using sha256
%% @end
%%--------------------------------------------------------------------
-spec verify(binary(), binary(), pubkey()) -> boolean().
verify(Bin, Signature, {ecc_compact, PubKey}) ->
    public_key:verify(Bin, sha256, Signature, PubKey);
verify(Bin, Signature, {ed25519, PubKey}) ->
    case enacl:sign_verify_detached(Signature, Bin, PubKey) of
        {ok, _} -> true;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% Binary to b58
%% @end
%%--------------------------------------------------------------------
-spec bin_to_b58(binary()) -> string().
bin_to_b58(Bin) ->
    bin_to_b58(16#00, Bin).

%%--------------------------------------------------------------------
%% @doc
%% Binary to b58
%% @end
%%--------------------------------------------------------------------
-spec bin_to_b58(non_neg_integer(), binary()) -> string().
bin_to_b58(Version, Bin) ->
    base58check_encode(Version, Bin).

%%--------------------------------------------------------------------
%% @doc
%% B58 to binary
%% @end
%%--------------------------------------------------------------------
-spec b58_to_bin(string())-> binary().
b58_to_bin(Str) ->
    {_, Addr} = b58_to_version_bin(Str),
    Addr.

%%--------------------------------------------------------------------
%% @doc
%% B58 to binary
%% @end
%%--------------------------------------------------------------------
-spec b58_to_version_bin(string())-> {Version::non_neg_integer(), binary()}.
b58_to_version_bin(Str) ->
    case base58check_decode(Str) of
        {ok, <<Version:8/unsigned-integer>>, Bin} -> {Version, Bin};
        {error, Reason} -> error(Reason)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Public key Binary to P2P address
%% @end
%%--------------------------------------------------------------------
-spec pubkey_bin_to_p2p(pubkey_bin()) -> string().
pubkey_bin_to_p2p(PubKey) when is_binary(PubKey) ->
    "/p2p/" ++ bin_to_b58(PubKey).

%%--------------------------------------------------------------------
%% @doc
%% P2P address to public key binary
%% @end
%%--------------------------------------------------------------------
-spec p2p_to_pubkey_bin(string()) -> pubkey_bin().
p2p_to_pubkey_bin(Str) ->
    case multiaddr:protocols(Str) of
        [{"p2p", B58Addr}] -> b58_to_bin(B58Addr);
        _ -> error(badarg)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec base58check_encode(non_neg_integer(), binary()) -> string().
base58check_encode(Version, Payload) when Version >= 0, Version =< 16#FF ->
  VPayload = <<Version:8/unsigned-integer, Payload/binary>>,
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


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

save_load_test() ->
    SaveLoad = fun(KeyType) ->
                       FileName = test_util:nonl(os:cmd("mktemp")),
                       Keys = generate_keys(KeyType),
                       ok = libp2p_crypto:save_keys(Keys, FileName),
                       {ok, LKeys} = load_keys(FileName),
                       ?assertEqual(LKeys, Keys)
               end,
    SaveLoad(ecc_compact),
    SaveLoad(ed25519),

    {error, _} = load_keys("no_such_file"),
    ok.

address_test() ->
    Roundtrip = fun(KeyType) ->
                        #{public := PubKey} = generate_keys(KeyType),

                        PubBin = pubkey_to_bin(PubKey),
                        PubB58 = bin_to_b58(PubBin),

                        MAddr = pubkey_bin_to_p2p(PubBin),
                        ?assertEqual(PubBin, p2p_to_pubkey_bin(MAddr)),

                        ?assertEqual(PubB58, pubkey_to_b58(PubKey)),
                        ?assertEqual(PubKey, b58_to_pubkey(PubB58))
                end,

    Roundtrip(ecc_compact),
    Roundtrip(ed25519),

    ok.

verify_sign_test() ->
    Bin = <<"sign me please">>,
    Verify = fun(KeyType) ->
                     #{secret := PrivKey, public := PubKey} = generate_keys(KeyType),
                     Sign = mk_sig_fun(PrivKey),
                     Signature = Sign(Bin),

                     ?assert(verify(Bin, Signature, PubKey)),
                     ?assert(not verify(<<"failed...">>, Signature, PubKey))
             end,

    Verify(ecc_compact),
    Verify(ed25519),

    ok.

verify_ecdh_test() ->
    Verify = fun(KeyType) ->
                     #{secret := PrivKey1, public := PubKey1} = generate_keys(KeyType),
                     #{secret := PrivKey2, public := PubKey2} = generate_keys(KeyType),
                     #{secret := _PrivKey3, public := PubKey3} = generate_keys(KeyType),
                     ECDH1 = mk_ecdh_fun(PrivKey1),
                     ECDH2 = mk_ecdh_fun(PrivKey2),

                     ?assertEqual(ECDH1(PubKey2), ECDH2(PubKey1)),
                     ?assertNotEqual(ECDH1(PubKey3), ECDH2(PubKey3))
             end,

    Verify(ecc_compact),
    Verify(ed25519),

    ok.

round_trip_short_key_test() ->
    ShortKeyMap = #{public =>
                    {ecc_compact,{{'ECPoint',<<4,2,151,174,89,188,129,160,76,
                                               74,234,246,22,24,16,96,70,219,
                                               183,246,235,40,90,107,29,126,
                                               74,14,11,201,75,2,168,74,18,
                                               165,99,26,32,161,195,100,232,
                                               40,130,76,231,85,239,255,213,
                                               129,210,184,181,233,79,154,11,
                                               229,103,160,213,105,208>>},
                                  {namedCurve,{1,2,840,10045,3,1,7}}}},
                    secret =>
                    {ecc_compact,{'ECPrivateKey',1,
                                  <<49,94,129,63,91,89,3,86,29,23,158,86,76,180,129,140,194,
                                    25,52,94,141,36,222,112,234,227,33,172,94,168,123>>,
                                  {namedCurve,{1,2,840,10045,3,1,7}},
                                  <<4,2,151,174,89,188,129,160,76,74,234,246,22,24,16,96,
                                    70,219,183,246,235,40,90,107,29,126,74,14,11,201,75,
                                    2,168,74,18,165,99,26,32,161,195,100,232,40,130,76,
                                    231,85,239,255,213,129,210,184,181,233,79,154,11,229,
                                    103,160,213,105,208>>}}},
    Bin = keys_to_bin(ShortKeyMap),
    ?assertEqual(ShortKeyMap, keys_from_bin(Bin)),
    ok.

-endif.
