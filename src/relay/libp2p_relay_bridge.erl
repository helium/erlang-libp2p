%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Bridge ==
%% Libp2p2 Relay Bridge API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_bridge).

-export([
    create_br/2
    ,create_ra/2
    ,create_ab/2
    ,a/1, b/1
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_bridge_br() :: #libp2p_relay_bridge_br_pb{}.
-type relay_bridge_ra() :: #libp2p_relay_bridge_ra_pb{}.
-type relay_bridge_ab() :: #libp2p_relay_bridge_ab_pb{}.

-export_type([relay_bridge_br/0]).
-export_type([relay_bridge_ra/0]).
-export_type([relay_bridge_ab/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridge B to R
%% @end
%%--------------------------------------------------------------------
-spec create_br(string(), string()) -> relay_bridge_br().
create_br(A, B) ->
    #libp2p_relay_bridge_br_pb{a=A, b=B}.

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridge R to A
%% @end
%%--------------------------------------------------------------------
-spec create_ra(string(), string()) -> relay_bridge_ra().
create_ra(A, B) ->
    #libp2p_relay_bridge_ra_pb{a=A, b=B}.

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridge R to A
%% @end
%%--------------------------------------------------------------------
-spec create_ab(string(), string()) -> relay_bridge_ra().
create_ab(A, B) ->
    #libp2p_relay_bridge_ab_pb{a=A, b=B}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec a(relay_bridge_br() | relay_bridge_ra()) -> string().
a(#libp2p_relay_bridge_br_pb{a=A}) ->
    A;
a(#libp2p_relay_bridge_ra_pb{a=A}) ->
    A;
a(#libp2p_relay_bridge_ab_pb{a=A}) ->
    A.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec b(relay_bridge_br() | relay_bridge_ra()) -> string().
b(#libp2p_relay_bridge_br_pb{b=B}) ->
    B;
b(#libp2p_relay_bridge_ra_pb{b=B}) ->
    B;
b(#libp2p_relay_bridge_ab_pb{b=B}) ->
    B.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_relay_bridge_br_pb{a="123", b="456"}, create_br("123", "456")),
    ?assertEqual(#libp2p_relay_bridge_ra_pb{a="123", b="456"}, create_ra("123", "456")),
    ?assertEqual(#libp2p_relay_bridge_ab_pb{a="123", b="456"}, create_ab("123", "456")).

get_test() ->
    Bridge = create_br("123", "456"),
    ?assertEqual("123", a(Bridge)),
    ?assertEqual("456", b(Bridge)).

-endif.
