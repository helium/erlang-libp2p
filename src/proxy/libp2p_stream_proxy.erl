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
    ,swarm :: pid() | undefined
    ,proxy :: pid() | undefined
    ,destination :: string() | undefined
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
    Destination = proplists:get_value(destination, Args),
    self() ! send_request,
    {ok, #state{destination=Destination}}.

handle_data(server, Data, State) ->
    Env = libp2p_proxy_envelope:decode(Data),
    {req, Req} = libp2p_proxy_envelope:data(Env),
    lager:info("server got proxy request ~p", [Req]),
    Destination = libp2p_proxy_req:address(Req),
    % TODO: Create new unique session with destination and the link the two sessions
    {noreply, State#state{destination=Destination}};
handle_data(client, _Data, State) ->
    {noreply, State}.

handle_info(client, send_request, #state{destination=Destination}=State) ->
    Req = libp2p_proxy_req:create(Destination),
    Env = libp2p_proxy_envelope:create(Req),
    {noreply, State, libp2p_proxy_envelope:encode(Env)};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
