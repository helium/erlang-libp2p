%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay Stream ==
%% @see libp2p_framed_stream
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
    type = bridge :: bridge | client,
    relay_addr :: string() | undefined,
    connection :: libp2p_connection:connection(),
    ping_timer = make_ref() :: reference(),
    ping_timeout_timer = make_ref() :: reference(),
    ping_seq = 1 :: pos_integer()
}).

-ifdef(TEST).
-define(RELAY_TIMEOUT, timer:seconds(5)).
-define(RELAY_PING_INTERVAL, timer:seconds(4)).
-define(RELAY_PING_TIMEOUT, timer:seconds(1)).
-else.
-define(RELAY_TIMEOUT, timer:minutes(5)).
-define(RELAY_PING_INTERVAL, timer:minutes(4)).
-define(RELAY_PING_TIMEOUT, timer:minutes(1)).
-endif.


-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

%% @hidden
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

%% @hidden
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------

%% @hidden
init(server, Conn, [_, _Pid, TID]=Args) ->
    lager:debug("init relay server with ~p", [{Conn, Args}]),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{swarm=Swarm, connection=Conn}};
init(client, Conn, Args) ->
    lager:debug("init relay client with ~p", [{Conn, Args}]),
    Swarm = proplists:get_value(swarm, Args),
    Ref = erlang:send_after(?RELAY_PING_INTERVAL, self(), send_ping),
    case proplists:get_value(type, Args, undefined) of
        undefined ->
            self() ! init_relay;
        {bridge_sc, Bridge} ->
            self() ! {init_bridge_sc, Bridge};
        {bridge_cr, CircuitAddress} ->
            {ok, {_Self, ServerAddress}} = libp2p_relay:p2p_circuit(CircuitAddress),
            self() ! {init_bridge_cr, ServerAddress}
    end,
    {ok, #state{swarm=Swarm, connection=Conn, ping_timer = Ref, ping_seq=1}}.

%% @hidden
handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

% Relay Step 1: Init relay, if listen_addrs, the client A create a relay request
% to be sent to the relay server R
%% @hidden
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
        ListenAddrs ->
            TID = libp2p_swarm:tid(Swarm),
            [ListenAddress|_] = libp2p_transport:sort_addrs(TID, ListenAddrs),
            Bridge = libp2p_relay_bridge:create_cr(Address, ListenAddress),
            EnvBridge = libp2p_relay_envelope:create(Bridge),
            {noreply, State, libp2p_relay_envelope:encode(EnvBridge)}
    end;
handle_info(client, ping_timeout, State) ->
    {stop, normal, State};
handle_info(client, send_ping, State = #state{ping_seq=Seq, relay_addr=undefined}) ->
    erlang:cancel_timer(State#state.ping_timer),
    Ping = libp2p_relay_ping:create_ping(Seq),
    Env = libp2p_relay_envelope:create(Ping),
    Ref = erlang:send_after(?RELAY_PING_TIMEOUT, self(), ping_timeout),
    {noreply, State#state{ping_timeout_timer=Ref}, libp2p_relay_envelope:encode(Env)};
handle_info(client, send_ping, State = #state{ping_seq=Seq, swarm=Swarm, relay_addr=RelayAddress}) ->
    erlang:cancel_timer(State#state.ping_timer),
    {ok, {RelayServer, _}} = libp2p_relay:p2p_circuit(RelayAddress),
    RelayServerPubKeyBin = libp2p_crypto:p2p_to_pubkey_bin(RelayServer),
    case libp2p_relay:is_valid_peer(Swarm, RelayServerPubKeyBin) of
        {error, _Reason} ->
            lager:error("failed to get peer for~p: ~p", [RelayServer, _Reason]),
            {stop, no_peer, State};
        false ->
            lager:warning("peer ~p is invalid going down", [RelayServer]),
            {stop, invalid_peer, State};
        true ->
            Ping = libp2p_relay_ping:create_ping(Seq),
            Env = libp2p_relay_envelope:create(Ping),
            Ref = erlang:send_after(?RELAY_PING_TIMEOUT, self(), ping_timeout),
            {noreply, State#state{ping_timeout_timer=Ref}, libp2p_relay_envelope:encode(Env)}
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

%% @hidden
terminate(_Type, _Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_server_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    Data = libp2p_relay_envelope:data(Env),
    handle_server_data(Data, Env, State).

% Relay Step 2: The relay server R receives a req craft the p2p-circuit address
% and sends it back to the client A
-spec handle_server_data(any(), libp2p_relay_envelope:relay_envelope() ,state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data({req, Req}, _Env, #state{swarm=Swarm}=State) ->
    Address = libp2p_relay_req:address(Req),
    true = libp2p_config:insert_relay_stream(libp2p_swarm:tid(Swarm), Address, self()),
    LocalP2PAddress = libp2p_swarm:p2p_address(Swarm),
    Resp = libp2p_relay_resp:create(libp2p_relay:p2p_circuit(LocalP2PAddress, Address)),
    EnvResp = libp2p_relay_envelope:create(Resp),
    libp2p_connection:set_idle_timeout(State#state.connection, ?RELAY_TIMEOUT),
    {noreply, State, libp2p_relay_envelope:encode(EnvResp)};
% Bridge Step 2: The relay server R receives a bridge request, finds it's relay
% stream to Server and sends it a message with bridge request. If this fails an error
% response will be sent back to B
handle_server_data({bridge_cr, Bridge}, _Env, #state{swarm=Swarm}=State) ->
    Server = libp2p_relay_bridge:server(Bridge),
    lager:debug("R got a relay request passing to Server's relay stream ~s", [Server]),
    case libp2p_config:lookup_relay_stream(libp2p_swarm:tid(Swarm), Server) of
        {ok, Pid} ->
            Pid ! {bridge_cr, Bridge},
            {noreply, State};
        false ->
            lager:error("fail to pass request ~p Server not found", [Bridge]),
            RespError = libp2p_relay_resp:create(Server, "server_down"),
            Env = libp2p_relay_envelope:create(RespError),
            {noreply, State, libp2p_relay_envelope:encode(Env)}
    end;
% Bridge Step 6: Client got dialed back from Server, that session (Server->Client) will be sent back to
% libp2p_transport_relay:connect to be used instead of the Client->Relay session
handle_server_data({bridge_sc, Bridge}, _Env,#state{swarm=Swarm, connection=Conn}=State) ->
    Client = libp2p_relay_bridge:client(Bridge),
    Server = libp2p_relay_bridge:server(Bridge),
    lager:debug("Client (~s) got Server (~s) dialing back", [Client, Server]),
    case libp2p_config:lookup_relay_sessions(libp2p_swarm:tid(Swarm), Server) of
        false ->
            ok;
        {ok, Pid} ->
            case libp2p_connection:session(Conn) of
                {error, _}=Error -> Pid ! Error;
                {ok, Session} -> Pid ! {session, Session}
            end
    end,
    {noreply, State};
handle_server_data({ping, Ping}, _Env, State) ->
    Pong = libp2p_relay_ping:create_pong(Ping),
    Env = libp2p_relay_envelope:create(Pong),
    {noreply, State, libp2p_relay_envelope:encode(Env)};
handle_server_data(_Data, _Env, State) ->
    lager:warning("server unknown envelope ~p", [_Env]),
    {noreply, State}.

-spec handle_client_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_client_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    Data = libp2p_relay_envelope:data(Env),
    handle_client_data(Data, Env, State).

-spec handle_client_data(any(), libp2p_relay_envelope:relay_envelope() ,state()) ->
    libp2p_framed_stream:handle_data_result().
handle_client_data({resp, Resp}, _Env, #state{swarm=Swarm}=State) ->
    Address = libp2p_relay_resp:address(Resp),
    case libp2p_relay_resp:error(Resp) of
        undefined ->
            % Relay Step 3: Client A receives a relay response from server R
            % with p2p-circuit address and inserts it as a new listener to get
            % broadcasted by peerbook
            ok = libp2p_relay_server:negotiated(Swarm, Address),
            libp2p_connection:set_idle_timeout(State#state.connection, ?RELAY_TIMEOUT),
            {noreply, State#state{relay_addr=Address}};
        Error ->
            % Bridge Step 3: An error is sent back to Client transfering to relay transport
            case libp2p_config:lookup_relay_sessions(libp2p_swarm:tid(Swarm), Address) of
                false -> ok;
                {ok, Pid} -> Pid ! {error, Error}
            end,
            {noreply, State}
    end;
% Bridge Step 4: Server got a bridge req, dialing Client
handle_client_data({bridge_rs, Bridge}, _Env, #state{swarm=Swarm}=State) ->
    Client = libp2p_relay_bridge:client(Bridge),
    lager:debug("Server got a bridge request dialing Client ~s", [Client]),
    case libp2p_relay:dial_framed_stream(Swarm, Client, [{type, {bridge_sc, Bridge}}]) of
        {ok, _} ->
            ok;
        {error, _Reason} ->
            lager:warning("failed to dial back client ~p", [_Reason])
    end,
    {noreply, State};
handle_client_data({ping, Pong}, _Env, #state{ping_seq=Seq}=State) ->
    case libp2p_relay_ping:seq(Pong) of
        Seq ->
            erlang:cancel_timer(State#state.ping_timeout_timer),
            Ref = erlang:send_after(?RELAY_PING_INTERVAL, self(), send_ping),
            {noreply, State#state{ping_seq=Seq+1, ping_timer=Ref}};
        OtherSeq ->
            lager:warning("Relay ping sequence invariant violated: expected ~p got ~p", [Seq, OtherSeq]),
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
