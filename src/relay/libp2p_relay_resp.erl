%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Responce ==
%% Libp2p2 Relay Responce API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_resp).

-export([
    create/1
    ,get/2
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_resp() :: #libp2p_RelayResp_pb{}.

-export_type([relay_resp/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay responce
%% @end
%%--------------------------------------------------------------------
-spec create(binary()) -> relay_resp().
create(Address) ->
    #libp2p_RelayResp_pb{address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec get(address, relay_resp()) -> binary().
get(address, Req) ->
    Req#libp2p_RelayResp_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_RelayResp_pb{address = <<"123">>}, create(<<"123">>)).

get_test() ->
    Resp = create(<<"123">>),
    ?assertEqual(<<"123">>, get(address, Resp)),
    ?assertException(error, function_clause, get(undefined, Resp)).

-endif.
