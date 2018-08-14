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
    swarm :: pid() | undefined
    ,p2p_circuit :: string() | undefined
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
    lager:info("init proxy server with ~p", [{_Conn, Args}]),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{swarm=Swarm}};
init(client, Conn, Args) ->
    lager:info("init proxy client with ~p", [{Conn, Args}]),
    case proplists:get_value(p2p_circuit, Args) of
        undefined ->
            {ok, #state{}};
        P2PCircuit ->
            self() ! send_request,
            {ok, #state{p2p_circuit=P2PCircuit}}
    end.

handle_data(server, Bin, State) ->
    handle_server_data(Bin, State);
handle_data(client, Bin, State) ->
    handle_client_data(Bin, State).

% STEP 1
handle_info(client, send_request, #state{p2p_circuit=P2P2PCircuit}=State) ->
    {ok, {_, AAddress}} = libp2p_relay:p2p_circuit(P2P2PCircuit),
    Req = libp2p_proxy_req:create(AAddress),
    Env = libp2p_proxy_envelope:create(P2P2PCircuit, Req),
    {noreply, State, libp2p_proxy_envelope:encode(Env)};
% STEP 3
handle_info(client, {dial_back_req, P2P2PCircuit}, State) ->
    {ok, {RAddress, _}} = libp2p_relay:p2p_circuit(P2P2PCircuit),
    DialBackReq = libp2p_proxy_dial_back_req:create(RAddress),
    Env = libp2p_proxy_envelope:create(P2P2PCircuit, DialBackReq),
    {noreply, State, libp2p_proxy_envelope:encode(Env)};
% STEP 5
handle_info(client, {dial_back_resp, P2P2PCircuit}, State) ->
    DialBackResp = libp2p_proxy_dial_back_resp:create(P2P2PCircuit),
    Env = libp2p_proxy_envelope:create(P2P2PCircuit, DialBackResp),
    {noreply, State, libp2p_proxy_envelope:encode(Env)};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec handle_server_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_server_data(Bin, State) ->
    Env = libp2p_proxy_envelope:decode(Bin),
    lager:notice("server got ~p", [Env]),
    Data = libp2p_proxy_envelope:data(Env),
    handle_server_data(Data, Env, State).

% STEP 2
-spec handle_server_data(any(), libp2p_proxy_envelope:proxy_envelope() ,state()) ->
    libp2p_framed_stream:handle_data_result().
handle_server_data({req, Req}, Env, #state{swarm=Swarm}=State) ->
    lager:info("server got proxy request ~p", [Req]),
    AAddress = libp2p_proxy_req:address(Req),
    {ok, Pid} = libp2p_proxy:dial_framed_stream(
        Swarm
        ,AAddress
        ,[]
    ),
    ID = libp2p_proxy_envelope:id(Env),
    Pid ! {dial_back_req, ID},
    {noreply, State};
% STEP 4
handle_server_data({dial_back_req, DialBack}, Env, #state{swarm=Swarm}=State) ->
    lager:info("server got proxy dial back ~p", [DialBack]),
    RAddress = libp2p_proxy_dial_back_req:address(DialBack),
    {ok, Pid} = libp2p_proxy:dial_framed_stream(
        Swarm
        ,RAddress
        ,[{unique_session, true}, {unique_port, true}]
    ),
    ID = libp2p_proxy_envelope:id(Env),
    Pid ! {dial_back_resp, ID},
    {noreply, State};
% STEP 6
handle_server_data({dial_back_resp, Resp}, _Env, State) ->
    % TODO: Bridge sessions/sockets here
    lager:info("server got resp  ~p", [Resp]),
    {noreply, State};
handle_server_data(_Data, _Env, State) ->
    lager:warning("server unknown envelope ~p", [_Env]),
    {noreply, State}.

-spec handle_client_data(binary(), state()) -> libp2p_framed_stream:handle_data_result().
handle_client_data(Bin, State) ->
    Env = libp2p_proxy_envelope:decode(Bin),
    lager:notice("client got ~p", [Env]),
    Data = libp2p_proxy_envelope:data(Env),
    handle_client_data(Data, Env, State).

handle_client_data(_Data, _Env, State) ->
    lager:warning("client unknown envelope ~p", [_Env]),
    {noreply, State}.


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
