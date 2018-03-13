-module(crypto_test).

-include_lib("public_key/include/public_key.hrl").

-include_lib("eunit/include/eunit.hrl").


generate_full_key() ->
    PrivKey = #'ECPrivateKey'{parameters=Params, publicKey=PubKeyPoint} =
        public_key:pem_entry_decode(lists:nth(2, public_key:pem_decode(list_to_binary(os:cmd("openssl ecparam -name prime256v1 -genkey -outform PEM"))))),
    PubKey = {#'ECPoint'{point=PubKeyPoint}, Params},
    case ecc_compact:is_compact(PubKey) of
        {true, _} -> generate_full_key();
        false -> {PrivKey, PubKey}
    end.


address_test() ->
    {ok, _PrivKey, CompactKey} = ecc_compact:generate_key(),
    PubKey = ecc_compact:recover_key(CompactKey),

    Address = libp2p_crypto:pubkey_to_address(PubKey),
    B58Address = libp2p_crypto:address_to_b58(Address),

    ?assertEqual(B58Address, libp2p_crypto:pubkey_to_b58(PubKey)),
    ?assertEqual(PubKey, libp2p_crypto:b58_to_pubkey(B58Address)),
    ?assertError(bad_checksum, libp2p_crypto:b58_to_address(B58Address ++ "bad")),

    {_, FullKey} = generate_full_key(),
    ?assertError(not_compact, libp2p_crypto:pubkey_to_address(FullKey)),

    ok.
