%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Responce ==
%% Libp2p2 Relay Responce API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_resp).

-export([
    create/1, create/2,
    address/1,
    error/1
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_resp() :: #libp2p_relay_resp_pb{address :: iolist(),
                                            error :: iolist() | undefined}.

-export_type([relay_resp/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay responce
%% @end
%%--------------------------------------------------------------------
-spec create(string()) -> relay_resp().
create(Address) ->
    #libp2p_relay_resp_pb{address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Create an relay responce
%% @end
%%--------------------------------------------------------------------
-spec create(string(), string()) -> relay_resp().
create(Address, Error) ->
    #libp2p_relay_resp_pb{address=Address, error=Error}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec address(relay_resp()) -> string() | undefined.
address(Req) ->
    Req#libp2p_relay_resp_pb.address.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec error(relay_resp()) -> string() | undefined.
error(Req) ->
    Req#libp2p_relay_resp_pb.error.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_relay_resp_pb{address="123", error=undefined}, create("123")),
    ?assertEqual(#libp2p_relay_resp_pb{address="123", error="error"}, create("123", "error")).

get_test() ->
    Resp = create("123"),
    ?assertEqual("123", address(Resp)),
    ?assertEqual(undefined, ?MODULE:error(Resp)),

    Error = create("123", "error"),
    ?assertEqual("123", address(Error)),
    ?assertEqual("error", ?MODULE:error(Error)).

-endif.
