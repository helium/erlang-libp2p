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
    ,create/1
    ,data/1
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_envelope() :: #libp2p_relay_envelope_pb{}.

-export_type([relay_envelope/0]).

%%--------------------------------------------------------------------
%% @doc
%% Decode relay_envelope binary to record
%% @end
%%--------------------------------------------------------------------
-spec decode(binary()) -> relay_envelope().
decode(Bin) when is_binary(Bin) ->
    libp2p_relay_pb:decode_msg(Bin, libp2p_relay_envelope_pb).

%%--------------------------------------------------------------------
%% @doc
%% Encode relay_envelope record to binary
%% @end
%%--------------------------------------------------------------------
-spec encode(relay_envelope()) -> binary().
encode(#libp2p_relay_envelope_pb{}=Env) ->
    libp2p_relay_pb:encode_msg(Env).

%%--------------------------------------------------------------------
%% @doc
%% Create an envelope
%% @end
%%--------------------------------------------------------------------
-spec create(libp2p_relay_req:relay_req()
             | libp2p_relay_resp:relay_resp()
             | libp2p_relay_bridge:relay_bridge_br()
             | libp2p_relay_bridge:relay_bridge_ra()
             | libp2p_relay_bridge:relay_bridge_ab()) -> relay_envelope().
create(#libp2p_relay_req_pb{}=Data) ->
    #libp2p_relay_envelope_pb{
        data={req, Data}
    };
create(#libp2p_relay_resp_pb{}=Data) ->
    #libp2p_relay_envelope_pb{
        data={resp, Data}
    };
create(#libp2p_relay_bridge_br_pb{}=Data) ->
    #libp2p_relay_envelope_pb{
        data={bridge_br, Data}
    };
create(#libp2p_relay_bridge_ra_pb{}=Data) ->
    #libp2p_relay_envelope_pb{
        data={bridge_ra, Data}
    };
create(#libp2p_relay_bridge_ab_pb{}=Data) ->
    #libp2p_relay_envelope_pb{
        data={bridge_ab, Data}
    }.


%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec data(relay_envelope()) -> {req, libp2p_relay_req:relay_req()}
                                | {resp, libp2p_relay_resp:relay_resp()}
                                | {bridge_br, libp2p_relay_bridge:relay_bridge_br()}
                                | {bridge_ra, libp2p_relay_bridge:relay_bridge_ra()}
                                | {bridge_ab, libp2p_relay_bridge:relay_bridge_ab()}.
data(Env) ->
    Env#libp2p_relay_envelope_pb.data.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

decode_encode_test() ->
    Req = libp2p_relay_req:create(<<"456">>),
    EnvEncoded = encode(create(Req)),
    EnvDecoded = decode(EnvEncoded),

    ?assertEqual({req, Req}, data(EnvDecoded)).

get_test() ->
    Req = libp2p_relay_req:create(<<"456">>),
    Env = create(Req),

    ?assertEqual({req, Req}, data(Env)).


-endif.
