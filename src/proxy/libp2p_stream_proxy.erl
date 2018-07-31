%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Proxy Stream ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_stream_proxy).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4
    ,client/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3
    ,handle_data/3
    ,handle_info/3
]).

-include("pb/libp2p_proxy_pb.hrl").

-record(state, {
    swarm
    ,sessionPid
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, [_, _Pid, TID]=Args) ->
    lager:info("init proxy server with ~p", [{_Conn, Args}]),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{swarm=Swarm}};
init(client, Conn, Args) ->
    lager:info("init proxy client with ~p", [{Conn, Args}]),
    {ok, #state{}}.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).


handle_info(_Type, _Msg, State) ->
    lager:notice("~p got ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_server_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data(Bin, State) ->
    Env = libp2p_proxy_envelope:decode(Bin),
    lager:notice("server got ~p", [Env]),
    Data = libp2p_proxy_envelope:data(Env),
    handle_server_data(Data, Env, State).

-spec handle_server_data(any(), libp2p_proxy_envelope:proxy_envelope() ,state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data({req, Req}, _Env, State) ->
    lager:warning("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Req]),
    {noreply, State};
handle_server_data(_Data, _Env, State) ->
    lager:warning("server unknown envelope ~p", [_Env]),
    {noreply, State}.

-spec handle_client_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_client_data(Bin, State) ->
    Env = libp2p_proxy_envelope:decode(Bin),
    lager:notice("client got ~p", [Env]),
    Data = libp2p_proxy_envelope:data(Env),
    handle_client_data(Data, Env, State).

-spec handle_client_data(any(), libp2p_proxy_envelope:proxy_envelope() ,state()) -> libp2p_framed_stream:handle_data_result().
handle_client_data(_Data, _Env, State) ->
    lager:warning("client unknown envelope ~p", [_Env]),
    {noreply, State}.
