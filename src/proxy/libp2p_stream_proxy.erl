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
    server/4,
    client/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("pb/libp2p_proxy_pb.hrl").

-record(state, {
    id :: binary() | undefined,
    transport :: pid() | undefined,
    swarm :: pid() | undefined,
    proxy_address :: undefined | string(),
    connection :: libp2p_connection:connection(),
    raw_connection :: libp2p_connection:connection() | undefined,
    connection_ref=make_ref() :: reference()
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
init(server, Conn, [_, _Pid, TID]=Args) ->
    lager:info("init proxy server with ~p", [{Conn, Args}]),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{swarm=Swarm, connection=Conn}};
init(client, Conn, Args) ->
    lager:info("init proxy client with ~p", [{Conn, Args}]),
    ID = proplists:get_value(id, Args),
    Swarm = proplists:get_value(swarm, Args),
    case proplists:get_value(p2p_circuit, Args) of
        undefined ->
            {ok, #state{swarm=Swarm, id=ID, connection=Conn}};
        P2PCircuit ->
            TransportPid = proplists:get_value(transport, Args),
            self() ! {proxy_req_send, P2PCircuit},
            {ok, #state{swarm=Swarm, id=ID, transport=TransportPid, connection=Conn}}

    end.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

% STEP 2
handle_info(client, {proxy_req_send, P2P2PCircuit}, #state{id=ID}=State) ->
    {ok, {PAddress, SAddress}} = libp2p_relay:p2p_circuit(P2P2PCircuit),
    Req = libp2p_proxy_req:create(SAddress),
    Env = libp2p_proxy_envelope:create(ID, Req),
    {noreply, State#state{proxy_address=PAddress}, libp2p_proxy_envelope:encode(Env)};
handle_info(client, proxy_overloaded, #state{swarm=Swarm, id=ID}=State) ->
    Overload = libp2p_proxy_overload:new(libp2p_swarm:pubkey_bin(Swarm)),
    Env = libp2p_proxy_envelope:create(ID, Overload),
    {stop, normal, State, libp2p_proxy_envelope:encode(Env)};
handle_info(server, {'DOWN', Ref, process, _, _}, State = #state{connection_ref=Ref}) ->
    {stop, normal, State};
handle_info(_Type, {transfer, Data}, State) ->
    lager:debug("~p transfering ~p", [_Type, Data]),
    {noreply, State, Data};
handle_info(_Type, stop, State) ->
    lager:debug("~p got stop order ~p", [_Type]),
    {stop, normal, State};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_server_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data(Bin, State) ->
    Env = libp2p_proxy_envelope:decode(Bin),
    lager:debug("server got ~p", [Env]),
    Data = libp2p_proxy_envelope:data(Env),
    handle_server_data(Data, Env, State).

% STEP 3
-spec handle_server_data(any(), libp2p_proxy_envelope:proxy_envelope() ,state()) ->
    libp2p_framed_stream:handle_data_result().
handle_server_data({req, Req}, Env, #state{swarm=Swarm}=State) ->
    lager:info("server got proxy request ~p", [Req]),
    ID = libp2p_proxy_envelope:id(Env),
    SAddress = libp2p_proxy_req:address(Req),
    case libp2p_proxy_server:proxy(Swarm, ID, self(), SAddress) of
        ok ->
            {noreply, State#state{id=ID}};
        {error, Reason} ->
            lager:warning("failed to init proxy ~p, sending back error", [Reason]),
            Error = libp2p_proxy_error:new(Reason),
            ErrorEnv = libp2p_proxy_envelope:create(ID, Error),
            {stop, normal, State, libp2p_proxy_envelope:encode(ErrorEnv)}
    end;
handle_server_data({dial_back, DialBack}, Env, State) ->
    lager:info("server got dial back request ~p", [DialBack]),
    case dial_back(Env, State) of
        {ok, Connection} ->
            {noreply, State#state{raw_connection=Connection}};
        {error, Reason} when Reason == timeout orelse
                             Reason == tcp_closed ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_server_data({resp, Resp}, _Env, #state{swarm=Swarm, raw_connection=Connection}=State) ->
    Socket = libp2p_connection:socket(Connection),
    Conn = libp2p_transport_tcp:new_connection(Socket, libp2p_proxy_resp:multiaddr(Resp)),
    Ref = erlang:make_ref(),
    TID = libp2p_swarm:tid(Swarm),
    {ok, Pid} = libp2p_transport:start_server_session(Ref, TID, Conn),
    MRef = erlang:monitor(process, Pid),
    Pid ! {shoot, Ref, ranch_tcp, Socket, 2000},
    lager:info("server got proxy resp ~p ~p", [Resp, Conn]),
    %% So this process apparently can't die, at least not yet
    %% instead remember the monitor ref for later
    {noreply, State#state{connection_ref=MRef}};
handle_server_data({overload, Overload}, _Env, #state{swarm=Swarm}=State) ->
    PubKeyBin = libp2p_proxy_overload:pub_key_bin(Overload),
    R = libp2p_crypto:pubkey_bin_to_p2p(PubKeyBin),
    A = libp2p_swarm:p2p_address(Swarm),
    P2PCircuit = libp2p_relay:p2p_circuit(R, A),
    lager:info("proxy server was overloaded, removing address: ~p", [P2PCircuit]),
    %% stop and start the relay to try to obtain a new peer
    libp2p_relay_server:stop(P2PCircuit, Swarm),
    libp2p_relay_server:relay(Swarm),
    {stop, normal, State};
handle_server_data(_Data, _Env, State) ->
    lager:warning("server unknown envelope ~p", [_Env]),
    {noreply, State}.

-spec handle_client_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_client_data(Bin, State) ->
    Env = libp2p_proxy_envelope:decode(Bin),
    lager:debug("client got ~p", [Env]),
    Data = libp2p_proxy_envelope:data(Env),
    handle_client_data(Data, Env, State).

handle_client_data({dial_back, DialBack}, Env, State) ->
    lager:info("client got dial back request ~p", [DialBack]),
    case dial_back(Env, State) of
        {ok, Connection} ->
            {noreply, State#state{raw_connection=Connection}};
        {error, Reason} when Reason == timeout orelse
                             Reason == etimedout orelse
                             Reason == ehostunreach orelse
                             Reason == tcp_closed ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_client_data({resp, Resp}, _Env, #state{transport=TransportPid,
                                              raw_connection=Connection}=State) ->
    lager:info("client got proxy resp ~p", [Resp]),
    {ok, Connection1} = libp2p_connection:controlling_process(Connection, TransportPid),
    Socket = libp2p_connection:socket(Connection1),
    TransportPid ! {proxy_negotiated, Socket, libp2p_proxy_resp:multiaddr(Resp)},
    {stop, normal, State};
handle_client_data({error, Error}, _Env, #state{transport=TransportPid}=State) ->
    lager:warning(" client got proxy error from server ~p", [Error]),
    Reason = libp2p_proxy_error:reason(Error),
    TransportPid ! {error, Reason},
    {stop, normal, State};
handle_client_data(_Data, _Env, State) ->
    lager:warning("client unknown envelope ~p", [_Env]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------

-spec dial_back(libp2p_proxy_envelope:proxy_envelope(), state()) -> {ok, libp2p_connection:connection()} | {error, any()}.
dial_back(Env, #state{connection=Connection, proxy_address=PAddr, swarm=Swarm}) ->
    {_, MultiAddrStr} = libp2p_connection:addr_info(Connection),
    MultiAddr = multiaddr:new(MultiAddrStr),
    [{"ip4", PAddress}, {"tcp", GuessPort}] = multiaddr:protocols(MultiAddr),
    %% ok, find the multiaddr with this TCP address in the peerbook entry for the proxy server's peerbook entry
    Port = case PAddr /= undefined andalso libp2p_peerbook:get(libp2p_swarm:peerbook(Swarm), libp2p_crypto:p2p_to_pubkey_bin(PAddr)) of
               false ->
                   %% we are a server
                   GuessPort;
               {ok, Peer} ->
                   PeerListenAddresses = libp2p_peer:listen_addrs(Peer),
                   lists:foldl(fun(MA, Acc) ->
                                      case multiaddr:protocols(multiaddr:new(MA)) of
                                          [{"ip4", PAddress}, {"tcp", PeerPort}] ->
                                              lager:info("Got port ~p from peerbook for ~p", [PeerPort, PAddr]),
                                              PeerPort;
                                          _ ->
                                              Acc
                                      end
                              end, GuessPort, PeerListenAddresses);
               PeerError ->
                   lager:warning("Failed to get peer port from peerbook for ~p ~p", [PAddress, PeerError]),
                   GuessPort
           end,
    ID = libp2p_proxy_envelope:id(Env),
    Opts = libp2p_transport_tcp:common_options(),
    case gen_tcp:connect(PAddress, erlang:list_to_integer(Port), Opts) of
        {ok, Socket} ->
            Path = libp2p_proxy:version() ++  "/" ++ base58:binary_to_base58(ID),
            Handlers = [{Path, <<"success">>}],
            RawConnection = libp2p_transport_tcp:new_connection(Socket),
            case libp2p_multistream_client:negotiate_handler(Handlers, Path, RawConnection) of
                {error, _Reason}=Error ->
                    lager:error("failed to negotiate_handler ~p ~p ~p, ~p", [Handlers, Path, RawConnection, _Reason]),
                    Error;
                server_switch ->
                    lager:error("failed to negotiate_handler ~p ~p ~p, ~p", [Handlers, Path, RawConnection, server_switch]),
                    {error, simultaneous_connection};
                {ok, _} -> {ok, RawConnection}
            end;
        Error ->
            lager:warning("Failed to dial back to ~p at ~p ~p: ~p", [PAddr, PAddress, Port, Error]),
            Error
    end.

-ifdef(TEST).
-endif.
