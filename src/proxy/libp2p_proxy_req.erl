%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Request ==
%% Libp2p2 Proxy Request API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_req).

-export([
    create/1
    ,path/1
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
-spec create(string()) -> proxy_req().
create(Path) ->
    #libp2p_proxy_req_pb{path=Path}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec path(proxy_req()) -> string().
path(Req) ->
    Req#libp2p_proxy_req_pb.path.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_req_pb{path="123"}, create("123")).

get_test() ->
    Req = create("123"),
    ?assertEqual("123", path(Req)).

-endif.
