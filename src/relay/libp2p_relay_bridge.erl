%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Relay Bridge ==
%% Libp2p2 Relay Bridge API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_bridge).

-export([
    create_cr/2
    ,create_rs/2
    ,create_sc/2
    ,server/1, client/1
]).

-include("pb/libp2p_relay_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type relay_bridge_cr() :: #libp2p_relay_bridge_cr_pb{}.
-type relay_bridge_rs() :: #libp2p_relay_bridge_rs_pb{}.
-type relay_bridge_sc() :: #libp2p_relay_bridge_sc_pb{}.

-export_type([relay_bridge_cr/0]).
-export_type([relay_bridge_rs/0]).
-export_type([relay_bridge_sc/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridge Client to Relay
%% @end
%%--------------------------------------------------------------------
-spec create_cr(string(), string()) -> relay_bridge_cr().
create_cr(Server, Client) ->
    #libp2p_relay_bridge_cr_pb{server=Server, client=Client}.

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridge Relay to Server
%% @end
%%--------------------------------------------------------------------
-spec create_rs(string(), string()) -> relay_bridge_rs().
create_rs(Server, Client) ->
    #libp2p_relay_bridge_rs_pb{server=Server, client=Client}.

%%--------------------------------------------------------------------
%% @doc
%% Create an relay bridge Server to Client
%% @end
%%--------------------------------------------------------------------
-spec create_sc(string(), string()) -> relay_bridge_sc().
create_sc(Server, Client) ->
    #libp2p_relay_bridge_sc_pb{server=Server, client=Client}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec server(relay_bridge_cr() | relay_bridge_rs() | relay_bridge_sc()) -> string().
server(#libp2p_relay_bridge_cr_pb{server=Server}) ->
    Server;
server(#libp2p_relay_bridge_rs_pb{server=Server}) ->
    Server;
server(#libp2p_relay_bridge_sc_pb{server=Server}) ->
    Server.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec client(relay_bridge_cr() | relay_bridge_rs() | relay_bridge_sc()) -> string().
client(#libp2p_relay_bridge_cr_pb{client=Client}) ->
    Client;
client(#libp2p_relay_bridge_rs_pb{client=Client}) ->
    Client;
client(#libp2p_relay_bridge_sc_pb{client=Client}) ->
    Client.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_relay_bridge_cr_pb{server="123", client="456"}, create_cr("123", "456")),
    ?assertEqual(#libp2p_relay_bridge_rs_pb{server="123", client="456"}, create_rs("123", "456")),
    ?assertEqual(#libp2p_relay_bridge_sc_pb{server="123", client="456"}, create_sc("123", "456")).

get_test() ->
    Bridge = create_cr("123", "456"),
    ?assertEqual("123", server(Bridge)),
    ?assertEqual("456", client(Bridge)).

-endif.
