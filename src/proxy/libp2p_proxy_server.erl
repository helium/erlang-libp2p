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
    ,proxy/4
    ,listener_loop/2
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
    tid :: ets:tab() | undefined
    ,swarm :: pid() | undefined
    ,port :: integer() | undefined
    ,data = maps:new() :: map()
}).

-record(pstate, {
    id :: binary() | undefined
    ,server_stream :: pid() | undefined
    ,client_stream :: pid() | undefined
    ,sockets = [] :: list()
}).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec proxy(pid(), binary(), pid(), string()) -> ok | {error, any()}.
proxy(Swarm, ID, ServerStream, AAddress) ->
    TID = libp2p_swarm:tid(Swarm),
    case libp2p_config:lookup_proxy(TID) of
        false ->
            {error, no_proxy};
        {ok, Pid} ->
            lager:info("handling proxy req ~p from ~p to ~p", [ID, ServerStream, AAddress]),
            gen_server:call(Pid, {init_proxy, ID, ServerStream, AAddress})
    end.

listener_loop(Server, ListenSocket) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    {ok, Packet} = gen_tcp:recv(Socket, 16),
    ok = gen_tcp:controlling_process(Socket, Server),
    Server ! {tcp, Socket, Packet},
    listener_loop(Server, ListenSocket).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID, Port]=Args) ->
    lager:info("~p init with ~p", [?MODULE, Args]),
    true = libp2p_config:insert_proxy(TID, self()),
    Swarm = libp2p_swarm:swarm(TID),
    ok = setup_listener(Port),
    {ok, #state{tid=TID, swarm=Swarm, port=Port}}.

handle_call({init_proxy, ID, ServerStream, AAddress}, _From, #state{data=Data}=State) ->
    PState = #pstate{
        id=ID
        ,server_stream=ServerStream
    },
    Data1 = maps:put(ID, PState, Data),
    self() ! {post_init, ID, AAddress},
    {reply, ok, State#state{data=Data1}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({post_init, ID, AAddress}, #state{swarm=Swarm, port=Port, data=Data}=State) ->
    {ok, ClientStream} = libp2p_proxy:dial_framed_stream(
        Swarm
        ,AAddress
        ,[{id, ID}]
    ),
    lager:info("dialed A (~p)", [AAddress]),
    PState = maps:get(ID, Data),
    #pstate{id=ID, server_stream=ServerStream} = PState,
    ok = dial_back(Swarm, Port, ID, ServerStream, ClientStream),
    PState1 = PState#pstate{client_stream=ClientStream},
    Data1 = maps:put(ID, PState1, Data),
    {noreply, State#state{data=Data1}};
handle_info({tcp, Socket, ID}, #state{data=Data}=State) ->
    Data1 = case maps:get(ID, Data, undefined) of
        undefined ->
            lager:warning("got unknown ID ~p closing ~p", [ID, Socket]),
            _ = gen_tcp:close(Socket),
            Data;
        #pstate{sockets=[]}=PState ->
            lager:info("got first socket ~p", [Socket]),
            PState1 = PState#pstate{sockets=[Socket]},
            maps:put(ID, PState1, Data);
        #pstate{sockets=[Socket1|[]]
                ,server_stream=ServerStream
                ,client_stream=ClientStream} ->
            lager:info("got second socket ~p", [Socket]),
            ok = splice(Socket1, Socket),
            ok = proxy_successful(ID, ServerStream, ClientStream),
            maps:remove(ID, Data)
    end,
    {noreply,State#state{data=Data1}};
handle_info({'DOWN', _Ref, process, Who, Reason}, State) ->
    lager:warning("splice process ~p went down: ~p", [Who, Reason]),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec setup_listener(integer()) -> ok.
setup_listener(Port) ->
    Server = self(),
    _Pid = erlang:spawn_link(fun() ->
        Opts = libp2p_transport_tcp:common_options(),
        {ok, LSock} = gen_tcp:listen(Port, Opts),
        lager:info("setting up listener (~p)", [LSock]),
        ?MODULE:listener_loop(Server, LSock)
    end),
    ok.

-spec dial_back(pid(), integer(), binary(), pid(), pid()) -> ok.
dial_back(_Swarm, Port, ID, ServerStream, ClientStream) ->
    % TODO: Should ask swarm for proxy address
    PAddress = "localhost",
    DialBack = libp2p_proxy_dial_back:create(PAddress, Port),
    EnvA = libp2p_proxy_envelope:create(ID, DialBack),
    EnvB = libp2p_proxy_envelope:create(ID, DialBack),
    ServerStream ! {transfer, libp2p_proxy_envelope:encode(EnvB)},
    ClientStream ! {transfer, libp2p_proxy_envelope:encode(EnvA)},
    ok.

-spec splice(inet:socket(), inet:socket()) -> ok.
splice(Socket1, Socket2) ->
    Pid = erlang:spawn(fun() ->
        receive control_given -> ok end,
        {ok, FD1} = inet:getfd(Socket1),
        {ok, FD2} = inet:getfd(Socket2),
        splicer:splice(FD1, FD2)
    end),
    _Ref = erlang:monitor(process, Pid),
    ok = gen_tcp:controlling_process(Socket1, Pid),
    ok = gen_tcp:controlling_process(Socket2, Pid),
    Pid ! control_given,
    lager:info("spice started @ ~p", [Pid]),
    ok.

-spec proxy_successful(binary(), pid(), pid()) -> ok.
proxy_successful(ID, ServerStream, ClientStream) ->
    ProxyResp = libp2p_proxy_resp:create(true),
    Env = libp2p_proxy_envelope:create(ID, ProxyResp),
    ServerStream ! {transfer, libp2p_proxy_envelope:encode(Env)},
    ClientStream ! {transfer, libp2p_proxy_envelope:encode(Env)},
    ok.