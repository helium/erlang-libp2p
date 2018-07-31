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
    ready = false :: boolean()
    ,swarm :: pid()
    ,proxy :: pid()
}).

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
    Proxy = proplists:get_value(proxy, Args),
    {ok, #state{proxy=Proxy}}.

handle_data(server, Data, #state{ready=false, swarm=Swarm}=State) ->
    Env = libp2p_proxy_envelope:decode(Data),
    lager:info("server got ~p", [Env]),
    {req, Req} = libp2p_proxy_envelope:data(Env),
    Path = libp2p_proxy_req:path(Req),
    Address = libp2p_proxy_req:address(Req),
    {ok, StreamPid} = libp2p_proxy:dial_framed_stream(
        Swarm
        ,Address
        ,Path
        ,[{proxy, self()}]
    ),
    {noreply, State#state{proxy=StreamPid, ready=true}};
handle_data(server, Data, #state{ready=true, proxy=Proxy}=State) ->
    lager:debug("server got data ~p, transfering to client", [Data]),
    Proxy ! {data, Data},
    {noreply, State};
handle_data(client, Data, #state{proxy=Proxy}=State) ->
    lager:debug("client got data ~p, transfering to server", [Data]),
    Proxy ! {data, Data},
    {noreply, State};
handle_data(client, _Data, State) ->
    {noreply, State}.


handle_info(_Type, {data, Data}, State) ->
    lager:debug("~p got data ~p, piping", [_Type, Data]),
    {noreply, State, Data};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
