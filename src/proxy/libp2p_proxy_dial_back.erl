%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Dial Back ==
%% Libp2p2 Proxy Dial Back API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_dial_back).

-export([
    create/2
    ,id/1
    ,address/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_dial_back() :: #libp2p_proxy_dial_back_pb{}.

-export_type([proxy_dial_back/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an proxy request
%% @end
%%--------------------------------------------------------------------
-spec create(binary(), string()) -> proxy_dial_back().
create(ID, Address) ->
    #libp2p_proxy_dial_back_pb{id=ID, address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec id(proxy_dial_back()) -> binary().
id(DialBack) ->
    DialBack#libp2p_proxy_dial_back_pb.id.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec address(proxy_dial_back()) -> string().
address(DialBack) ->
    DialBack#libp2p_proxy_dial_back_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_dial_back_pb{id= <<"123">>, address="456"}, create(<<"123">>, "456")).

get_test() ->
    DialBack = create(<<"123">>, "456"),
    ?assertEqual(<<"123">>, id(DialBack)),
    ?assertEqual("456", address(DialBack)).

-endif.
