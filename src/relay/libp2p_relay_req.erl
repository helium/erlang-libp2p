%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Request ==
%% Libp2p2 Relay Request API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_req).

-export([
    create/1
    ,get/2
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_req() :: #libp2p_RelayReq_pb{}.

-export_type([relay_req/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay request
%% @end
%%--------------------------------------------------------------------
-spec create(binary()) -> relay_req().
create(Address) ->
    #libp2p_RelayReq_pb{address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec get(address, relay_req()) -> binary().
get(address, Req) ->
    Req#libp2p_RelayReq_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_RelayReq_pb{address = <<"123">>}, create(<<"123">>)).

get_test() ->
    Req = create(<<"123">>),
    ?assertEqual(<<"123">>, get(address, Req)),
    ?assertException(error, function_clause, get(undefined, Req)).

-endif.
