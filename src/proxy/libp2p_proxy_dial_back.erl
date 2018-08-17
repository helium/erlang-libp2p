%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Dial Back ==
%% Libp2p2 Proxy Dial Back API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_dial_back).

-export([
    create/2
    ,address/1
    ,port/1
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
-spec create(string(), integer()) -> proxy_dial_back().
create(Address, Port) ->
    #libp2p_proxy_dial_back_pb{address=Address, port=Port}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec address(proxy_dial_back()) -> string().
address(DialBack) ->
    DialBack#libp2p_proxy_dial_back_pb.address.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec port(proxy_dial_back()) -> integer().
port(DialBack) ->
    DialBack#libp2p_proxy_dial_back_pb.port.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_dial_back_pb{address="456", port=9090}, create("456", 9090)).

get_test() ->
    DialBack = create("456", 9090),
    ?assertEqual("456", address(DialBack)),
    ?assertEqual(9090, port(DialBack)).

-endif.
