%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Request ==
%% Libp2p2 Relay Request API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_req).

-export([
    create/1,
    address/1
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_req() :: #libp2p_relay_req_pb{address :: iolist()}.

-export_type([relay_req/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay request
%% @end
%%--------------------------------------------------------------------
-spec create(string()) -> relay_req().
create(Address) ->
    #libp2p_relay_req_pb{address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec address(relay_req()) -> string().
address(Req) ->
    Req#libp2p_relay_req_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_relay_req_pb{address="123"}, create("123")).

get_test() ->
    Req = create("123"),
    ?assertEqual("123", address(Req)).

-endif.
