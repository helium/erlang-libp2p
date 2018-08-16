%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Proxy Server ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_server).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1
    ,handle_call/3
    ,handle_cast/2
    ,handle_info/2
    ,terminate/2
    ,code_change/3
]).

-record(state, {
    id :: binary() | undefined
    ,swarm :: pid() | undefined
    ,server_stream :: pid() | undefined
    ,client_stream :: pid() | undefined
    ,sockets = [] :: list()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:warning("init with ~p", [Args]),
    ID = proplists:get_value(id, Args),
    ServerStream = proplists:get_value(server_stream, Args),
    Swarm = proplists:get_value(swarm, Args),
    AAddress = proplists:get_value(a_address, Args),
    self() ! {dial_a, AAddress},
    {ok, #state{id=ID, swarm=Swarm, server_stream=ServerStream}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({dial_a, AAddress}, #state{id=ID, swarm=Swarm}=State) ->
    {ok, Pid} = libp2p_proxy:dial_framed_stream(
        Swarm
        ,AAddress
        ,[{id, ID}]
    ),
    lager:info("dialed A (~p)", [AAddress]),
    self() ! setup_listener,
    {noreply, State#state{client_stream=Pid}};
handle_info(setup_listener, #state{id=ID, server_stream=ServerStream
                                         ,client_stream=ClientStream}=State) ->
    Server = self(),
    Port = 8080,
    _Pid = erlang:spawn(fun() ->
        {ok, LSock} = gen_tcp:listen(8080, [binary, {packet, raw}, {active, false}]),
        lager:info("setting up listener"),

        {ok, SockA} = gen_tcp:accept(LSock),
        {ok, PacketA} = gen_tcp:recv(SockA, 16),
        ok = gen_tcp:controlling_process(SockA, Server),
        Server ! {tcp, SockA, PacketA},

        {ok, SockB} = gen_tcp:accept(LSock),
        {ok, PacketB} = gen_tcp:recv(SockB, 16),
        ok = gen_tcp:controlling_process(SockB, Server),
        Server ! {tcp, SockB, PacketB},
        receive stop -> gen_tcp:close(LSock) end
    end),
    PAddress = "localhost",
    DialBack = libp2p_proxy_dial_back:create(PAddress, Port),
    EnvA = libp2p_proxy_envelope:create(ID, DialBack),
    EnvB = libp2p_proxy_envelope:create(ID, DialBack),
    ServerStream ! {transfer, libp2p_proxy_envelope:encode(EnvB)},
    ClientStream ! {transfer, libp2p_proxy_envelope:encode(EnvA)},
    {noreply, State};
handle_info({tcp, Socket, ID}, #state{id=ID, sockets=[]}=State) ->
    lager:info("got first socket ~p", [Socket]),
    {noreply, State#state{sockets=[Socket]}};
handle_info({tcp, Socket, ID}, #state{id=ID, sockets=[_S|[]]=Sockets}=State) ->
    lager:info("got second socket ~p", [Socket]),
    self() ! splice,
    {noreply, State#state{sockets=[Socket|Sockets]}};
handle_info(splice, #state{sockets=[S1, S2]}=State) ->
    % TODO: cleanup listener when splice is done
    Pid = erlang:spawn(fun() ->
        receive control_given -> ok end,
        {ok, FD1} = inet:getfd(S1),
        {ok, FD2} = inet:getfd(S2),
        splicer:splice(FD1, FD2)
    end),
    _Ref = erlang:monitor(process, Pid),
    ok = gen_tcp:controlling_process(S1, Pid),
    ok = gen_tcp:controlling_process(S2, Pid),
    Pid ! control_given,
    lager:info("spice started @ ~p", [Pid]),
    self() ! proxy_successful,
    {noreply, State};
handle_info({'DOWN', _Ref, process, Who, Reason}, State) ->
    lager:warning("splice process ~p went down: ~p", [Who, Reason]),
    {noreply, State};
handle_info(proxy_successful, #state{id=ID, server_stream=ServerStream
                                            ,client_stream=ClientStream}=State) ->
    ProxyResp = libp2p_proxy_resp:create(true),
    Env = libp2p_proxy_envelope:create(ID, ProxyResp),
    ServerStream ! {transfer, libp2p_proxy_envelope:encode(Env)},
    ClientStream ! {transfer, libp2p_proxy_envelope:encode(Env)},
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

% TODO: Find real proxy address


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
