%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Envelope ==
%% Libp2p2 Proxy Envelope API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_envelope).

-export([
    decode/1
    ,encode/1
    ,create/1
    ,data/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_envelope() :: #libp2p_proxy_envelope_pb{}.

-export_type([proxy_envelope/0]).

%%--------------------------------------------------------------------
%% @doc
%% Decode proxy_envelope binary to record
%% @end
%%--------------------------------------------------------------------
-spec decode(binary()) -> proxy_envelope().
decode(Bin) when is_binary(Bin) ->
    libp2p_proxy_pb:decode_msg(Bin, libp2p_proxy_envelope_pb).

%%--------------------------------------------------------------------
%% @doc
%% Encode proxy_envelope record to binary
%% @end
%%--------------------------------------------------------------------
-spec encode(proxy_envelope()) -> binary().
encode(#libp2p_proxy_envelope_pb{}=Env) ->
    libp2p_proxy_pb:encode_msg(Env).

%%--------------------------------------------------------------------
%% @doc
%% Create an envelope
%% @end
%%--------------------------------------------------------------------
-spec create(libp2p_proxy_req:proxy_req()) -> proxy_envelope().
create(#libp2p_proxy_req_pb{}=Data) ->
    #libp2p_proxy_envelope_pb{
        data={req, Data}
    }.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec data(proxy_envelope()) -> {req, libp2p_proxy_req:proxy_req()}.
data(Env) ->
    Env#libp2p_proxy_envelope_pb.data.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

decode_encode_test() ->
    Req = libp2p_proxy_req:create("456"),
    EnvEncoded = encode(create(Req)),
    EnvDecoded = decode(EnvEncoded),

    ?assertEqual({req, Req}, data(EnvDecoded)).

get_test() ->
    Req = libp2p_proxy_req:create("456"),
    Env = create(Req),

    ?assertEqual({req, Req}, data(Env)).

-endif.
