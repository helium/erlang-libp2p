%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Dial Back Request ==
%% Libp2p2 Proxy Dial Back Request API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_dial_back_req).

-export([
    create/1
    ,address/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_dial_back_req() :: #libp2p_proxy_dial_back_req_pb{}.

-export_type([proxy_dial_back_req/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an proxy request
%% @end
%%--------------------------------------------------------------------
-spec create(string()) -> proxy_dial_back_req().
create(Address) ->
    #libp2p_proxy_dial_back_req_pb{address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec address(proxy_dial_back_req()) -> string().
address(Req) ->
    Req#libp2p_proxy_dial_back_req_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_dial_back_req_pb{address="456"}, create("456")).

get_test() ->
    Req = create("456"),
    ?assertEqual("456", address(Req)).

-endif.
