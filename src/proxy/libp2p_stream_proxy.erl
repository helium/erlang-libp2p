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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("pb/libp2p_proxy_pb.hrl").

-record(state, {
    id :: binary() | undefined
    ,transport :: pid() | undefined
    ,swarm :: pid() | undefined
    ,socket :: inet:socket() | undefined
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
    {ok, #state{swarm=Swarm}};
init(client, Conn, Args) ->
    lager:info("init proxy client with ~p", [{Conn, Args}]),
    ID = proplists:get_value(id, Args),
    case proplists:get_value(p2p_circuit, Args) of
        undefined ->
            {ok, #state{id=ID}};
        P2PCircuit ->
            TransportPid = proplists:get_value(transport, Args),
            self() ! {proxy_req_send, P2PCircuit},
            {ok, #state{id=ID, transport=TransportPid}}

    end.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

% STEP 2
handle_info(client, {proxy_req_send, P2P2PCircuit}, #state{id=ID}=State) ->
    {ok, {_, AAddress}} = libp2p_relay:p2p_circuit(P2P2PCircuit),
    Req = libp2p_proxy_req:create(AAddress),
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
    AAddress = libp2p_proxy_req:address(Req),
    ok = libp2p_proxy_server:proxy(Swarm, ID, self(), AAddress),
    {noreply, State#state{id=ID}};
handle_server_data({dial_back, DialBack}, Env, State) ->
    lager:info("server got dial back request ~p", [DialBack]),
    {ok, Socket} = dial_back(DialBack, Env),
    {noreply, State#state{socket=Socket}};
handle_server_data({resp, Resp}, _Env, #state{swarm=Swarm, socket=Socket}=State) ->
    Conn = libp2p_transport_tcp:new_connection(Socket),
    Ref = erlang:make_ref(),
    TID = libp2p_swarm:tid(Swarm),
    {ok, Pid} = libp2p_transport:start_server_session(Ref, TID, Conn),
    Pid ! {shoot, Ref, ranch_tcp, Socket, 2000},
    lager:info("server got proxy resp ~p", [Resp]),
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
    {ok, Socket} = dial_back(DialBack, Env),
    {noreply, State#state{socket=Socket}};
handle_client_data({resp, Resp}, _Env, #state{transport=TransportPid
                                              ,socket=Socket}=State) ->
    lager:info("client got proxy resp ~p", [Resp]),
    ok = gen_tcp:controlling_process(Socket, TransportPid),
    TransportPid ! {proxy_negotiated, Socket},
    {noreply, State};
handle_client_data(_Data, _Env, State) ->
    lager:warning("client unknown envelope ~p", [_Env]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------

-spec dial_back(libp2p_proxy_dial_back:proxy_dial_back()
                ,libp2p_proxy_envelope:proxy_envelope()) -> {ok, inet:socket()}.
dial_back(DialBack, Env) ->
    ID = libp2p_proxy_envelope:id(Env),
    PAddress = libp2p_proxy_dial_back:address(DialBack),
    Port = libp2p_proxy_dial_back:port(DialBack),
    Opts = libp2p_transport_tcp:common_options(),
    {ok, Socket} = gen_tcp:connect(PAddress, Port, Opts),
    ok = gen_tcp:send(Socket, ID),
    {ok, Socket}.

-ifdef(TEST).
-endif.
