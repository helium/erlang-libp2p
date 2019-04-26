%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Proxy Session ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_session).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_server/4
]).

-spec start_server(libp2p_connection:connection(), string(), ets:tab(), []) -> ok.
start_server(Connection, Path, TID, []) ->
    %% In libp2p_swarm, the server takes over the calling process
    %% since it's fired of synchronously by a multistream. Since ranch
    %% already assigned the controlling process, there is no need to
    %% wait for a shoot message
    lager:info("doing socket transfer"),
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    %% we want to unregister this as a session because it's not a real
    %% session on the proxy server, we track proxy connections elsewhere
    libp2p_config:remove_session(TID, RemoteAddr),
    <<"/", ID0/binary>> = erlang:list_to_binary(Path),
    ID1 = base58:base58_to_binary(erlang:binary_to_list(ID0)),
    %% this will block until the connection is finished with
    ok = libp2p_proxy_server:connection(TID, Connection, ID1),
    %% we did our job, time to die
    ok.
