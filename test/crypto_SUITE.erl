-module(crypto_SUITE).

-include_lib("public_key/include/public_key.hrl").

-include_lib("common_test/include/ct.hrl").


-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([save_load_test/1, address_test/1]).

all() ->
    [address_test, save_load_test].

generate_full_key() ->
    PrivKey = #'ECPrivateKey'{parameters=Params, publicKey=PubKeyPoint} =
        public_key:pem_entry_decode(lists:nth(2, public_key:pem_decode(list_to_binary(os:cmd("openssl ecparam -name prime256v1 -genkey -outform PEM"))))),
    PubKey = {#'ECPoint'{point=PubKeyPoint}, Params},
    case ecc_compact:is_compact(PubKey) of
        {true, _} -> generate_full_key();
        false -> {PrivKey, PubKey}
    end.

init_per_testcase(save_load_test, Config) ->
    FileName = "crypto_" ++ integer_to_list(erlang:phash2(make_ref())),
    [{filename, FileName} | Config];
init_per_testcase(_, Config) ->
    Config.


end_per_testcase(save_load_test, Config) ->
    FileName = proplists:get_value(filename, Config),
    file:delete(FileName);
end_per_testcase(_, _) ->
    ok.


save_load_test(Config) ->
    FileName = proplists:get_value(filename, Config),
    Keys = {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
    ok = libp2p_crypto:save_keys(Keys, FileName),
    {ok, LPrivKey, LPubKey} = libp2p_crypto:load_keys(FileName),
    {PrivKey, PubKey} = {LPrivKey, LPubKey},
    {error, _} = libp2p_crypto:load_keys(FileName ++ "no"),
    ok.

address_test(_Config) ->
    {_PrivKey, PubKey} = libp2p_crypto:generate_keys(),

    Address = libp2p_crypto:pubkey_to_address(PubKey),
    B58Address = libp2p_crypto:address_to_b58(Address),

    B58Address = libp2p_crypto:pubkey_to_b58(PubKey),
    PubKey = libp2p_crypto:b58_to_pubkey(B58Address),


    {'EXIT', {bad_checksum, _}} = (catch libp2p_crypto:b58_to_address(B58Address ++ "bad")),

    {_, FullKey} = generate_full_key(),
    {'EXIT', {not_compact, _}} = (catch libp2p_crypto:pubkey_to_address(FullKey)),
    ok.
