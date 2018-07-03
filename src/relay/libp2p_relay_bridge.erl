%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Bridge ==
%% Libp2p2 Relay Bridge API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_bridge).

-export([
    create/2
    ,get/2
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_bridge() :: #libp2p_RelayBridge_pb{}.

-export_type([relay_bridge/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridgeuest
%% @end
%%--------------------------------------------------------------------
-spec create(binary(), binary()) -> relay_bridge().
create(From, To) ->
    #libp2p_RelayBridge_pb{from=From, to=To}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec get(from | to, relay_bridge()) -> binary().
get(from, Bridge) ->
    Bridge#libp2p_RelayBridge_pb.from;
get(to, Bridge) ->
    Bridge#libp2p_RelayBridge_pb.to.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_RelayBridge_pb{from = <<"123">>, to = <<"456">>}, create(<<"123">>, <<"456">>)).

get_test() ->
    Bridge = create(<<"123">>, <<"456">>),
    ?assertEqual(<<"123">>, get(from, Bridge)),
    ?assertEqual(<<"456">>, get(to, Bridge)),
    ?assertException(error, function_clause, get(undefined, Bridge)).

-endif.
