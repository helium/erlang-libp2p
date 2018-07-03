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
    case proplists:get_value(relay, Args) of
        undefined ->
            self() ! init_relay;
        RelayAddress ->
            [_Self, DestinationAddress] = string:split(RelayAddress, "/p2p-circuit"),
            self() ! {init_bridge, DestinationAddress}
    end,
    TID = libp2p_swarm:tid(Swarm),
    {_Local, Remote} = libp2p_connection:addr_info(Conn),
    {ok, SessionPid} = libp2p_config:lookup_session(TID, Remote, []),
    {ok, #state{swarm=Swarm, sessionPid=SessionPid}}.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

handle_info(server, _Msg, State) ->
    lager:notice("server got ~p", [_Msg]),
    {noreply, State};
handle_info(client, init_relay, #state{swarm=Swarm}=State) ->
    case libp2p_swarm:listen_addrs(Swarm) of
        [] ->
            lager:info("no listen addresses for ~p, relay disabled", [Swarm]),
            {noreply, State};
        [Address|_] ->
            EnvId = <<"123">>,
            Req = libp2p_relay_req:create(erlang:list_to_binary(Address)),
            EnvReq = libp2p_relay_envelope:create(EnvId, Req),
            {noreply, State, libp2p_relay_envelope:encode(EnvReq)}
    end;
handle_info(client, {init_bridge, Address}, State) ->
    EnvId = <<"123">>,
    Des = libp2p_relay_bridge:create(<<"from">>, erlang:list_to_binary(Address)),
    EnvDes = libp2p_relay_envelope:create(EnvId, Des),
    {noreply, State, libp2p_relay_envelope:encode(EnvDes)};
handle_info(client, _Msg, State) ->
    lager:notice("client got ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_server_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    lager:notice("server got ~p", [Env]),
    Data = libp2p_relay_envelope:get(data, Env),
    handle_server_data(Data, Env, State).

handle_server_data({relayReq, Req}, Env, #state{swarm=Swarm}=State) ->
    EnvId = libp2p_relay_envelope:get(id, Env),
    Address = libp2p_relay_req:get(address, Req),
    [LocalAddress|_] = libp2p_swarm:listen_addrs(Swarm),
    Resp = libp2p_relay_resp:create(<<(erlang:list_to_binary(LocalAddress))/binary, "/p2p-circuit", Address/binary>>),
    EnvResp = libp2p_relay_envelope:create(EnvId, Resp),
    {noreply, State, libp2p_relay_envelope:encode(EnvResp)};
handle_server_data({relayBridge, _Des}, _Env, #state{swarm=_Swarm}=State) ->
    % Create bridge here
    % The relay sawrm shoudl tell the destination swarm (A/To) to connect to B (From)
    {noreply, State};
handle_server_data(_Data, _Env, State) ->
    lager:warning("unknown envelope ~p", [_Env]),
    {noreply, State}.


handle_client_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    lager:notice("client got ~p", [Env]),
    Data = libp2p_relay_envelope:get(data, Env),
    handle_client_data(Data, Env, State).

handle_client_data({relayResp, Resp}, _Env, #state{swarm=Swarm, sessionPid=SessionPid}=State) ->
    Address = erlang:binary_to_list(libp2p_relay_resp:get(address, Resp)),
    TID = libp2p_swarm:tid(Swarm),
    lager:info("inserting new listerner ~p, ~p, ~p", [TID, Address, SessionPid]),
    true = libp2p_config:insert_listener(TID, [Address], SessionPid),
    {noreply, State};
handle_client_data(_Data, _Env, State) ->
    lager:warning("unknown envelope ~p", [_Env]),
    {noreply, State}.
