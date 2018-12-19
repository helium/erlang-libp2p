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
    connection :: libp2p_connection:connection(),
    raw_connection :: libp2p_connection:connection() | undefined
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
    case proplists:get_value(p2p_circuit, Args) of
        undefined ->
            {ok, #state{id=ID, connection=Conn}};
        P2PCircuit ->
            TransportPid = proplists:get_value(transport, Args),
            self() ! {proxy_req_send, P2PCircuit},
            {ok, #state{id=ID, transport=TransportPid, connection=Conn}}

    end.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

% STEP 2
handle_info(client, {proxy_req_send, P2P2PCircuit}, #state{id=ID}=State) ->
    {ok, {_, SAddress}} = libp2p_relay:p2p_circuit(P2P2PCircuit),
    Req = libp2p_proxy_req:create(SAddress),
    Env = libp2p_proxy_envelope:create(ID, Req),
    {noreply, State, libp2p_proxy_envelope:encode(Env)};
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
            {stop, Reason, State}
    end;
handle_server_data({dial_back, DialBack}, Env, State) ->
    lager:info("server got dial back request ~p", [DialBack]),
    {ok, Connection} = dial_back(Env, State),
    {noreply, State#state{raw_connection=Connection}};
handle_server_data({resp, Resp}, _Env, #state{swarm=Swarm, raw_connection=Connection}=State) ->
    Socket = libp2p_connection:socket(Connection),
    Conn = libp2p_transport_tcp:new_connection(Socket, libp2p_proxy_resp:multiaddr(Resp)),
    Ref = erlang:make_ref(),
    TID = libp2p_swarm:tid(Swarm),
    {ok, Pid} = libp2p_transport:start_server_session(Ref, TID, Conn),
    Pid ! {shoot, Ref, ranch_tcp, Socket, 2000},
    lager:info("server got proxy resp ~p ~p", [Resp, Conn]),
    {noreply, State};
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
    {ok, Connection} = dial_back(Env, State),
    {noreply, State#state{raw_connection=Connection}};
handle_client_data({resp, Resp}, _Env, #state{transport=TransportPid,
                                              raw_connection=Connection}=State) ->
    lager:info("client got proxy resp ~p", [Resp]),
    {ok, Connection1} = libp2p_connection:controlling_process(Connection, TransportPid),
    Socket = libp2p_connection:socket(Connection1),
    TransportPid ! {proxy_negotiated, Socket, libp2p_proxy_resp:multiaddr(Resp)},
    {noreply, State};
handle_client_data(_Data, _Env, State) ->
    lager:warning("client unknown envelope ~p", [_Env]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------

-spec dial_back(libp2p_proxy_envelope:proxy_envelope(), state()) -> {ok, libp2p_connection:connection()}.
dial_back(Env, #state{connection=Connection}) ->
    {_, MultiAddrStr} = libp2p_connection:addr_info(Connection),
    MultiAddr = multiaddr:new(MultiAddrStr),
    [{"ip4", PAddress}, {"tcp", Port}] = multiaddr:protocols(MultiAddr),
    ID = libp2p_proxy_envelope:id(Env),
    Opts = libp2p_transport_tcp:common_options(),
    {ok, Socket} = gen_tcp:connect(PAddress, erlang:list_to_integer(Port), Opts),
    Path = libp2p_proxy:version() ++  "/" ++ base58:binary_to_base58(ID),
    Handlers = [{Path, <<"success">>}],
    RawConnection = libp2p_transport_tcp:new_connection(Socket),
    {ok, _} = libp2p_multistream_client:negotiate_handler(Handlers, Path, RawConnection),
    {ok, RawConnection}.

-ifdef(TEST).
-endif.
