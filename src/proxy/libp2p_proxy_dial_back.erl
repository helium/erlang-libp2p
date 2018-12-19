%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Dial Back ==
%% Libp2p2 Proxy Dial Back API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_dial_back).

-export([
    create/0
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
-spec create() -> proxy_dial_back().
create() ->
    #libp2p_proxy_dial_back_pb{}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_dial_back_pb{}, create()).

-endif.
