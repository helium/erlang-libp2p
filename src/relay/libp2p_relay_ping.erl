%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Ping ==
%% Libp2p2 Relay Request API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_ping).

-export([
    create_ping/1,
    create_pong/1,
    seq/1
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_ping() :: #libp2p_relay_ping_pb{}.

-export_type([relay_ping/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create a relay ping
%% @end
%%--------------------------------------------------------------------
-spec create_ping(non_neg_integer()) -> relay_ping().
create_ping(Seq) ->
    #libp2p_relay_ping_pb{seq=Seq, direction='PING'}.

%%--------------------------------------------------------------------
%% @doc
%% Create a relay pong
%% @end
%%--------------------------------------------------------------------
-spec create_pong(relay_ping()) -> relay_ping().
create_pong(#libp2p_relay_ping_pb{seq=Seq, direction='PING'}) ->
    #libp2p_relay_ping_pb{seq=Seq, direction='PONG'}.

%%--------------------------------------------------------------------
%% @doc
%% Access relay ping/pong sequence number
%% @end
%%--------------------------------------------------------------------
-spec seq(relay_ping()) -> non_neg_integer().
seq(#libp2p_relay_ping_pb{seq=Seq, direction='PONG'}) ->
    Seq.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_ping_test() ->
    ?assertEqual(#libp2p_relay_ping_pb{seq=123, direction='PING'}, create_ping(123)).

create_pong_test() ->
    ?assertEqual(#libp2p_relay_ping_pb{seq=123, direction='PONG'}, create_pong(create_ping(123))).

-endif.
