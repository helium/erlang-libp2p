%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay Stream ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_stream_relay).

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

-include("pb/libp2p_relay_pb.hrl").

-record(state, {
    swarm
    ,sessionPid
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
    lager:info("init server with ~p", [{_Conn, Args}]),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{swarm=Swarm}};
init(client, Conn, Args) ->
    lager:info("init client with ~p", [{Conn, Args}]),
    Swarm = proplists:get_value(swarm, Args),
    TID = libp2p_swarm:tid(Swarm),
    {_Local, Remote} = libp2p_connection:addr_info(Conn),
    {ok, SessionPid} = libp2p_config:lookup_session(TID, Remote, []),
    self() ! init_relay,
    {ok, #state{swarm=Swarm, sessionPid=SessionPid}}.

handle_data(server, Data, #state{swarm=Swarm}=State) ->
    Env = libp2p_relay_envelope:decode(Data),
    lager:notice("server got ~p", [Env]),
    {relayReq, Req} = libp2p_relay_envelope:get(data, Env),
    EnvId = libp2p_relay_envelope:get(id, Env),
    Address = libp2p_relay_req:get(address, Req),
    [_Address1|_] = libp2p_swarm:listen_addrs(Swarm),
    Resp = libp2p_relay_resp:create(Address),
    EnvResp = libp2p_relay_envelope:create(EnvId, Resp),
    {noreply, State, libp2p_relay_envelope:encode(EnvResp)};
handle_data(client, Data, #state{swarm=Swarm, sessionPid=SessionPid}=State) ->
    Env = libp2p_relay_envelope:decode(Data),
    lager:notice("client got ~p", [Env]),
    {relayResp, Resp} = libp2p_relay_envelope:get(data, Env),
    Address = erlang:binary_to_list(libp2p_relay_resp:get(address, Resp)),
    TID = libp2p_swarm:tid(Swarm),
    lager:info("inserting new listerner ~p, ~p, ~p", [TID, Address, SessionPid]),
    true = libp2p_config:insert_listener(TID, [Address], SessionPid),
    lager:warning("[~p:~p:~p] MARKER ~p", [?MODULE, ?FUNCTION_NAME, ?LINE, 1]),
    {noreply, State}.

handle_info(server, _Msg, State) ->
    lager:notice("server got ~p", [_Msg]),
    {noreply, State};
handle_info(client, init_relay, #state{swarm=Swarm}=State) ->
    [Address|_] = libp2p_swarm:listen_addrs(Swarm),
    EnvId = <<"123">>,
    Req = libp2p_relay_req:create(erlang:list_to_binary(Address)),
    EnvReq = libp2p_relay_envelope:create(EnvId, Req),
    {noreply, State, libp2p_relay_envelope:encode(EnvReq)};
handle_info(client, _Msg, State) ->
    lager:notice("client got ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
