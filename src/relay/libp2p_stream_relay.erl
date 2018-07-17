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
% Relay Step 1: Init relay, if listen_addrs, the client A create a relay request
% to be sent to the relay server R
handle_info(client, init_relay, #state{swarm=Swarm}=State) ->
    case libp2p_swarm:listen_addrs(Swarm) of
        [] ->
            lager:info("no listen addresses for ~p, relay disabled", [Swarm]),
            {noreply, State};
        [Address|_] ->
            true = erlang:register(erlang:list_to_atom(Address), self()),
            Req = libp2p_relay_req:create(erlang:list_to_binary(Address)),
            EnvReq = libp2p_relay_envelope:create(Req),
            {noreply, State, libp2p_relay_envelope:encode(EnvReq)}
    end;
% Bridge Step 1: Init bridge, if listen_addrs, the client B create a relay bridge
% to be sent to the relay server R
handle_info(client, {init_bridge, Address}, #state{swarm=Swarm}=State) ->
    case libp2p_swarm:listen_addrs(Swarm) of
        [] ->
            lager:warning("no listen addresses for ~p, bridge failed", [Swarm]),
            {noreply, State};
        [ListenAddress|_] ->
            Bridge = libp2p_relay_bridge:create_br(erlang:list_to_binary(ListenAddress)
                                                   ,erlang:list_to_binary(Address)),
            EnvBridge = libp2p_relay_envelope:create(Bridge),
            {noreply, State, libp2p_relay_envelope:encode(EnvBridge)}
    end;
% Bridge Step 3: The relay server R (stream to A) receives a bridge request
% and transfers it to A.
handle_info(client, {bridge_br, Bridge}, State) ->
    lager:notice("client got bridge request ~p", [Bridge]),
    lager:warning("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, 1]),
    {noreply, State, <<>>};
handle_info(client, _Msg, State) ->
    lager:notice("client got ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_server_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    lager:notice("server got ~p", [Env]),
    Data = libp2p_relay_envelope:data(Env),
    handle_server_data(Data, Env, State).

% Relay Step 2: The relay server R receives a req craft the p2p-circuit address
% and sends it back to the client A
handle_server_data({req, Req}, _Env, #state{swarm=Swarm}=State) ->
    Address = libp2p_relay_req:address(Req),
    [LocalAddress|_] = libp2p_swarm:listen_addrs(Swarm),
    Resp = libp2p_relay_resp:create(<<(erlang:list_to_binary(LocalAddress))/binary, "/p2p-circuit", Address/binary>>),
    EnvResp = libp2p_relay_envelope:create(Resp),
    {noreply, State, libp2p_relay_envelope:encode(EnvResp)};
% Bridge Step 2: The relay server R receives a bridge request, finds it's relay
% stream to A and sends it a message with bridge request
handle_server_data({bridge_br, Bridge}, _Env, #state{swarm=_Swarm}=State) ->
    B = erlang:binary_to_list(libp2p_relay_bridge:b(Bridge)),
    lager:info("R got relay request passing to A's relay stream ~s", [B]),
    erlang:list_to_atom(B) ! {bridge_br, Bridge},
    {noreply, State};
handle_server_data(_Data, _Env, State) ->
    lager:warning("unknown envelope ~p", [_Env]),
    {noreply, State}.


handle_client_data(Bin, State) ->
    Env = libp2p_relay_envelope:decode(Bin),
    lager:notice("client got ~p", [Env]),
    Data = libp2p_relay_envelope:data(Env),
    handle_client_data(Data, Env, State).

% Relay Step 3: Client A receives a relay response from server R with p2p-circuit address
% and inserts it as a new listerner to get broadcasted by peerbook
handle_client_data({resp, Resp}, _Env, #state{swarm=Swarm, sessionPid=SessionPid}=State) ->
    Address = erlang:binary_to_list(libp2p_relay_resp:address(Resp)),
    TID = libp2p_swarm:tid(Swarm),
    lager:info("inserting new listerner ~p, ~p, ~p", [TID, Address, SessionPid]),
    true = libp2p_config:insert_listener(TID, [Address], SessionPid),
    {noreply, State};
handle_client_data(_Data, _Env, State) ->
    lager:warning("unknown envelope ~p", [_Env]),
    {noreply, State}.
