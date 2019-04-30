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
    server/4,
    client/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3,
    terminate/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("pb/libp2p_relay_pb.hrl").

-record(state, {
    swarm :: pid() | undefined,
    sessionPid :: pid() | undefined,
    type = bridge :: bridge | client,
    relay_addr :: string() | undefined
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
    lager:debug("init relay server with ~p", [{_Conn, Args}]),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{swarm=Swarm}};
init(client, Conn, Args) ->
    lager:debug("init relay client with ~p", [{Conn, Args}]),
    Swarm = proplists:get_value(swarm, Args),
    case proplists:get_value(type, Args, undefined) of
        undefined ->
            self() ! init_relay;
        {bridge_sc, Bridge} ->
            self() ! {init_bridge_sc, Bridge};
        {bridge_cr, CircuitAddress} ->
            {ok, {_Self, ServerAddress}} = libp2p_relay:p2p_circuit(CircuitAddress),
            self() ! {init_bridge_cr, ServerAddress}
    end,
    {ok, SessionPid} = libp2p_connection:session(Conn),
    {ok, #state{swarm=Swarm, sessionPid=SessionPid}}.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

% Relay Step 1: Init relay, if listen_addrs, the client A create a relay request
% to be sent to the relay server R
handle_info(client, init_relay, #state{swarm=Swarm}=State) ->
    case libp2p_swarm:listen_addrs(Swarm) of
        [] ->
            lager:debug("no listen addresses for ~p, relay disabled", [Swarm]),
            {stop, no_listen_address, State};
        [_|_] ->
            Address = libp2p_swarm:p2p_address(Swarm),
            Req = libp2p_relay_req:create(Address),
            EnvReq = libp2p_relay_envelope:create(Req),
            {noreply, State#state{type=client}, libp2p_relay_envelope:encode(EnvReq)}
    end;
% Bridge Step 1: Init bridge, if listen_addrs, the Client create a relay bridge
% to be sent to the relay server R
handle_info(client, {init_bridge_cr, Address}, #state{swarm=Swarm}=State) ->
    case libp2p_swarm:listen_addrs(Swarm) of
        [] ->
            lager:warning("no listen addresses for ~p, bridge failed", [Swarm]),
            {noreply, State};
        [ListenAddress|_] ->
            Bridge = libp2p_relay_bridge:create_cr(Address, ListenAddress),
            EnvBridge = libp2p_relay_envelope:create(Bridge),
            {noreply, State, libp2p_relay_envelope:encode(EnvBridge)}
    end;
% Bridge Step 3: The relay server R (stream to Server) receives a bridge request
% and transfers it to Server.
handle_info(server, {bridge_cr, BridgeCR}, State) ->
    lager:notice("client got bridge request ~p", [BridgeCR]),
    Server = libp2p_relay_bridge:server(BridgeCR),
    Client = libp2p_relay_bridge:client(BridgeCR),
    BridgeRS = libp2p_relay_bridge:create_rs(Server, Client),
    EnvBridge = libp2p_relay_envelope:create(BridgeRS),
    {noreply, State, libp2p_relay_envelope:encode(EnvBridge)};
% Bridge Step 5: Sending bridge Server/Client request to Client
handle_info(client, {init_bridge_sc, BridgeSC}, State) ->
    lager:notice("client init bridge Server to Client ~p", [BridgeSC]),
    Server = libp2p_relay_bridge:server(BridgeSC),
    Client = libp2p_relay_bridge:client(BridgeSC),
    Bridge = libp2p_relay_bridge:create_sc(Server, Client),
    EnvBridge = libp2p_relay_envelope:create(Bridge),
    {noreply, State, libp2p_relay_envelope:encode(EnvBridge)};
handle_info(server, stop, State) ->
    {stop, normal, State};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got unknown info message ~p", [_Type, _Msg]),
    {noreply, State}.

terminate(client, _Reason, #state{type=client, swarm=Swarm, relay_addr=RelayAddress}) ->
    erlang:spawn(fun() ->
        _ = libp2p_relay_server:connection_lost(Swarm),
        TID = libp2p_swarm:tid(Swarm),
        _ = libp2p_config:remove_listener(TID, RelayAddress)
    end),
    ok;
terminate(_Type, _Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_server_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    lager:notice("server got ~p", [Env]),
    Data = libp2p_relay_envelope:data(Env),
    handle_server_data(Data, Env, State).

% Relay Step 2: The relay server R receives a req craft the p2p-circuit address
% and sends it back to the client A
-spec handle_server_data(any(), libp2p_relay_envelope:relay_envelope() ,state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data({req, Req}, _Env, #state{swarm=Swarm}=State) ->
    Address = libp2p_relay_req:address(Req),
    true = libp2p_relay:reg_addr_stream(Address, self()),
    LocalP2PAddress = libp2p_swarm:p2p_address(Swarm),
    Resp = libp2p_relay_resp:create(libp2p_relay:p2p_circuit(LocalP2PAddress, Address)),
    EnvResp = libp2p_relay_envelope:create(Resp),
    {noreply, State, libp2p_relay_envelope:encode(EnvResp)};
% Bridge Step 2: The relay server R receives a bridge request, finds it's relay
% stream to Server and sends it a message with bridge request. If this fails an error
% response will be sent back to B
handle_server_data({bridge_cr, Bridge}, _Env, #state{swarm=_Swarm}=State) ->
    Server = libp2p_relay_bridge:server(Bridge),
    lager:debug("R got a relay request passing to Server's relay stream ~s", [Server]),
    try libp2p_relay:reg_addr_stream(Server) ! {bridge_cr, Bridge} of
        _ ->
            {noreply, State}
    catch
        What:Why ->
            lager:error("fail to pass request Server seems down ~p/~p", [What, Why]),
            RespError = libp2p_relay_resp:create(Server, "server_down"),
            Env = libp2p_relay_envelope:create(RespError),
            {noreply, State, libp2p_relay_envelope:encode(Env)}
    end;
% Bridge Step 6: Client got dialed back from Server, that session (Server->Client) will be sent back to
% libp2p_transport_relay:connect to be used instead of the Client->Relay session
handle_server_data({bridge_sc, Bridge}, _Env,#state{swarm=Swarm}=State) ->
    Client = libp2p_relay_bridge:client(Bridge),
    Server = libp2p_relay_bridge:server(Bridge),
    lager:debug("Client (~s) got Server (~s) dialing back", [Client, Server]),
    SessionPids = [Pid || {_, Pid} <- libp2p_swarm:sessions(Swarm)],
    catch libp2p_relay:reg_addr_sessions(Server) ! {sessions, SessionPids},
    {noreply, State};
handle_server_data(_Data, _Env, State) ->
    lager:warning("server unknown envelope ~p", [_Env]),
    {noreply, State}.

-spec handle_client_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_client_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    lager:notice("client got ~p", [Env]),
    Data = libp2p_relay_envelope:data(Env),
    handle_client_data(Data, Env, State).

-spec handle_client_data(any(), libp2p_relay_envelope:relay_envelope() ,state()) ->
    libp2p_framed_stream:handle_data_result().
handle_client_data({resp, Resp}, _Env, #state{swarm=Swarm, sessionPid=SessionPid}=State) ->
    Address = libp2p_relay_resp:address(Resp),
    case libp2p_relay_resp:error(Resp) of
        undefined ->
            % Relay Step 3: Client A receives a relay response from server R
            % with p2p-circuit address and inserts it as a new listener to get
            % broadcasted by peerbook
            TID = libp2p_swarm:tid(Swarm),
            lager:debug("inserting new listener ~p, ~p, ~p", [TID, Address, SessionPid]),
            true = libp2p_config:insert_listener(TID, [Address], SessionPid),
            {noreply, State#state{relay_addr=Address}};
        Error ->
            % Bridge Step 3: An error is sent back to Client transfering to relay transport
            catch libp2p_relay:reg_addr_sessions(Address) ! {error, Error},
            {noreply, State}
    end;
% Bridge Step 4: Server got a bridge req, dialing Client
handle_client_data({bridge_rs, Bridge}, _Env, #state{swarm=Swarm}=State) ->
    Client = libp2p_relay_bridge:client(Bridge),
    lager:debug("Server got a bridge request dialing Client ~s", [Client]),
    case libp2p_relay:dial_framed_stream(Swarm, Client, [{type, {bridge_sc, Bridge}}]) of
        {ok, _} ->
            {noreply, State};
        {error, _} ->
            {stop, normal, State}
    end;
handle_client_data(_Data, _Env, State) ->
    lager:warning("client unknown envelope ~p", [_Env]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
