%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Request ==
%% Libp2p2 Proxy Request API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_req).

-export([
    create/2
    ,path/1
    ,address/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_req() :: #libp2p_proxy_req_pb{}.

-export_type([proxy_req/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an proxy request
%% @end
%%--------------------------------------------------------------------
-spec create(string(), string()) -> proxy_req().
create(Path, Address) ->
    #libp2p_proxy_req_pb{path=Path, address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec path(proxy_req()) -> string().
path(Req) ->
    Req#libp2p_proxy_req_pb.path.

-spec address(proxy_req()) -> string().
address(Req) ->
    Req#libp2p_proxy_req_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_req_pb{path="123", address="456"}, create("123", "456")).

get_test() ->
    Req = create("123", "456"),
    ?assertEqual("123", path(Req)),
    ?assertEqual("456", address(Req)).

-endif.
