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
    ,create/2
    ,id/1
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
-spec create(string(), libp2p_proxy_req:proxy_req()
                       | libp2p_proxy_req:proxy_req()
                       | libp2p_proxy_dial_back_req:proxy_dial_back_req()
                       | libp2p_proxy_dial_back_resp:proxy_dial_back_resp()) -> proxy_envelope().
create(ID, #libp2p_proxy_req_pb{}=Data) ->
    #libp2p_proxy_envelope_pb{
        id=ID
        ,data={req, Data}
    };
create(ID, #libp2p_proxy_resp_pb{}=Data) ->
    #libp2p_proxy_envelope_pb{
        id=ID
        ,data={resp, Data}
    };
create(ID, #libp2p_proxy_dial_back_req_pb{}=Data) ->
    #libp2p_proxy_envelope_pb{
        id=ID
        ,data={dial_back_req, Data}
    };
create(ID, #libp2p_proxy_dial_back_resp_pb{}=Data) ->
    #libp2p_proxy_envelope_pb{
        id=ID
        ,data={dial_back_resp, Data}
    }.


%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec id(proxy_envelope()) -> string().
id(Env) ->
    Env#libp2p_proxy_envelope_pb.id.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec data(proxy_envelope()) -> {req, libp2p_proxy_req:proxy_req()}
                                | {resp, libp2p_proxy_resp:proxy_resp()}
                                | {dial_back_req, libp2p_proxy_dial_back_req:proxy_dial_back_req()}
                                | {dial_back_resp, libp2p_proxy_dial_back_resp:proxy_dial_back_resp()}.
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
    EnvEncoded = encode(create("123", Req)),
    EnvDecoded = decode(EnvEncoded),

    ?assertEqual("123", id(EnvDecoded)),
    ?assertEqual({req, Req}, data(EnvDecoded)).

get_test() ->
    Req = libp2p_proxy_req:create("456"),
    Env = create("123", Req),

    ?assertEqual("123", id(Env)),
    ?assertEqual({req, Req}, data(Env)).

-endif.
