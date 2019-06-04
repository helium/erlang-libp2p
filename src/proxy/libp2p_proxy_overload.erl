%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Overload ==
%% Libp2p2 Proxy Overload API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_overload).

-export([
    new/1,
    pub_key_bin/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_overload() :: #libp2p_proxy_overload_pb{}.

-export_type([proxy_overload/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an proxy respuest
%% @end
%%--------------------------------------------------------------------
-spec new(libp2p_crypto:pubkey_bin()) -> proxy_overload().
new(PubKeyBin) ->
    #libp2p_proxy_overload_pb{pub_key_bin=PubKeyBin}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec pub_key_bin(proxy_overload()) -> libp2p_crypto:pubkey_bin().
pub_key_bin(Overload) ->
    Overload#libp2p_proxy_overload_pb.pub_key_bin.
    
%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    ?assertEqual(#libp2p_proxy_overload_pb{pub_key_bin= <<"pubkeybin">>}, new(<<"pubkeybin">>)).

get_test() ->
    Overload = new(<<"pubkeybin">>),
    ?assertEqual(<<"pubkeybin">>, pub_key_bin(Overload)).

-endif.
