%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Envelope ==
%% Libp2p2 Relay Envelope API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_envelope).

-export([
    decode/1
    ,encode/1
    ,create/2
    ,get/2
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_envelope() :: #libp2p_RelayEnvelope_pb{}.

-export_type([relay_envelope/0]).

%%--------------------------------------------------------------------
%% @doc
%% Decode relay_envelope binary to record
%% @end
%%--------------------------------------------------------------------
-spec decode(binary()) -> relay_envelope().
decode(Bin) when is_binary(Bin) ->
    libp2p_relay_pb:decode_msg(Bin, libp2p_RelayEnvelope_pb).

%%--------------------------------------------------------------------
%% @doc
%% Encode relay_envelope record to binary
%% @end
%%--------------------------------------------------------------------
-spec encode(relay_envelope()) -> binary().
encode(#libp2p_RelayEnvelope_pb{}=Env) ->
    libp2p_relay_pb:encode_msg(Env).

%%--------------------------------------------------------------------
%% @doc
%% Create an envelope
%% @end
%%--------------------------------------------------------------------
-spec create(binary(), libp2p_relay_req:relay_req()
                       | libp2p_relay_resp:relay_resp()
                       | libp2p_relay_bridge:relay_bridge()) -> relay_envelope().
create(Id, #libp2p_RelayReq_pb{}=Data) ->
    #libp2p_RelayEnvelope_pb{
        id=Id
        ,data={relayReq, Data}
    };
create(Id, #libp2p_RelayResp_pb{}=Data) ->
    #libp2p_RelayEnvelope_pb{
        id=Id
        ,data={relayResp, Data}
    };
create(Id, #libp2p_RelayBridge_pb{}=Data) ->
    #libp2p_RelayEnvelope_pb{
        id=Id
        ,data={relayBridge, Data}
    }.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec get(id | data, relay_envelope()) -> binary()
                                         | {relayReq, libp2p_relay_req:relay_req()}
                                         | {relayResp, libp2p_relay_resp:relay_resp()}
                                         | {relayBridge, libp2p_relay_bridge:relay_bridge()}.
get(id, Env) ->
    Env#libp2p_RelayEnvelope_pb.id;
get(data, Env) ->
    Env#libp2p_RelayEnvelope_pb.data.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

decode_encode_test() ->
    EnvId = <<"123">>,
    Req = libp2p_relay_req:create(<<"456">>),
    EnvEncoded = encode(create(EnvId, Req)),
    EnvDecoded = decode(EnvEncoded),

    ?assertEqual(EnvId, get(id, EnvDecoded)),
    ?assertEqual({relayReq, Req}, get(data, EnvDecoded)).

get_test() ->
    EnvId = <<"123">>,
    Req = libp2p_relay_req:create(<<"456">>),
    Env =create(EnvId, Req),

    ?assertEqual(EnvId, get(id, Env)),
    ?assertEqual({relayReq, Req}, get(data, Env)),
    ?assertException(error, function_clause, get(undefined, Env)).


-endif.
