%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Error ==
%% Libp2p2 Proxy Error API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_error).

-export([
    new/1,
    reason/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_error() :: #libp2p_proxy_error_pb{reason :: iodata()}.

-export_type([proxy_error/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an proxy respuest
%% @end
%%--------------------------------------------------------------------
-spec new(atom()) -> proxy_error().
new(Reason) ->
    #libp2p_proxy_error_pb{reason=erlang:atom_to_binary(Reason, utf8)}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec reason(proxy_error()) -> atom().
reason(Error) ->
    erlang:binary_to_atom(Error#libp2p_proxy_error_pb.reason, utf8).
    
%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    ?assertEqual(#libp2p_proxy_error_pb{reason= <<"error">>}, new(error)).

get_test() ->
    Error = new(error),
    ?assertEqual(error, reason(Error)).

-endif.
