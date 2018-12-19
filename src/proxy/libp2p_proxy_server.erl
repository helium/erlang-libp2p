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
    ,connection/3
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
    ,data = maps:new() :: map()
}).

-record(pstate, {
    id :: binary() | undefined
    ,server_stream :: pid() | undefined
    ,client_stream :: pid() | undefined
    ,connections = [] :: [libp2p_connection:connection()]
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec connection(ets:tab(),libp2p_connection:connection(), binary()) -> ok | {error, any()}.
connection(TID, Connection, ID) ->
    case libp2p_config:lookup_proxy(TID) of
        false ->
            {error, no_proxy};
        {ok, Pid} ->
            lager:info("handling proxy connection ~p from ~p to ~p ~p", [Connection, ID, Pid]),
            {ok, _} = libp2p_connection:controlling_process(Connection, Pid),
            gen_server:cast(Pid, {connection, Connection, ID})
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID]=Args) ->
    lager:info("~p init with ~p", [?MODULE, Args]),
    true = libp2p_config:insert_proxy(TID, self()),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{tid=TID, swarm=Swarm}}.

handle_call({init_proxy, ID, ServerStream, SAddress}, _From, #state{data=Data}=State) ->
    PState = #pstate{
        id=ID
        ,server_stream=ServerStream
    },
    Data1 = maps:put(ID, PState, Data),
    self() ! {post_init, ID, SAddress},
    {reply, ok, State#state{data=Data1}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({connection, Connection, ID0}, #state{data=Data}=State) ->
    %% possibly reverse the ID if we got it from the client
    ID = get_id(ID0, Data),
    Data1 = case maps:get(ID, Data, undefined) of
        undefined ->
            lager:warning("got unknown ID ~p closing ~p", [ID, Connection]),
            _ = libp2p_connection:close(Connection),
            Data;
        #pstate{connections=[]}=PState ->
            lager:info("got first Connection ~p", [Connection]),
            PState1 = PState#pstate{connections=[Connection]},
            maps:put(ID, PState1, Data);
        #pstate{connections=[Connection1|[]]
                ,server_stream=ServerStream
                ,client_stream=ClientStream} ->
            lager:info("got second connection ~p", [Connection]),
            %% TODO what kind of multiaddr should we send back, the p2p circuit address or
            %% the underlying transport?
            % TODO_PROXY: Still needed?
            {ServerMA, ClientMA} =
                case ID0 =:= ID of
                    true ->
                        %% server's connection
                        {_, SN} = libp2p_connection:addr_info(Connection),
                        {_, CN} = libp2p_connection:addr_info(Connection1),
                        {SN, CN};
                    false ->
                        %% client's connection because it has been reversed
                        {_, SN} = libp2p_connection:addr_info(Connection1),
                        {_, CN} = libp2p_connection:addr_info(Connection),
                        {SN, CN}
                end,
            ok = splice(Connection1, Connection),
            ok = proxy_successful(ID, ServerMA, ServerStream, ClientMA, ClientStream),
            maps:remove(ID, Data)
    end,
    {noreply,State#state{data=Data1}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({post_init, ID, SAddress}, #state{swarm=Swarm, data=Data}=State) ->
    Res = libp2p_proxy:dial_framed_stream(Swarm, SAddress, [{id, ID}]),
    case Res of
        {ok, ClientStream} ->
            lager:info("dialed A (~p)", [SAddress]),
            PState = maps:get(ID, Data),
            #pstate{id=ID, server_stream=ServerStream} = PState,
            ok = dial_back(ID, ServerStream, ClientStream),
            PState1 = PState#pstate{client_stream=ClientStream},
            Data1 = maps:put(ID, PState1, Data),
            {noreply, State#state{data=Data1}};
        _ ->
            {noreply, State}
    end;
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

-spec dial_back(binary(), pid(), pid()) -> ok.
dial_back(ID, ServerStream, ClientStream) ->
    DialBack = libp2p_proxy_dial_back:create(),
    %% reverse the ID for the client so we can distinguish
    CEnv = libp2p_proxy_envelope:create(reverse_id(ID), DialBack),
    SEnv = libp2p_proxy_envelope:create(ID, DialBack),
    ServerStream ! {transfer, libp2p_proxy_envelope:encode(SEnv)},
    ClientStream ! {transfer, libp2p_proxy_envelope:encode(CEnv)},
    ok.

-spec splice(libp2p_connection:connection(), libp2p_connection:connection()) -> ok.
splice(Connection1, Connection2) ->
    {Pid, _Ref} = erlang:spawn_monitor(fun() ->
        receive control_given -> ok end,
        Socket1 = libp2p_connection:socket(Connection1),
        {ok, FD1} = inet:getfd(Socket1),
        Socket2 = libp2p_connection:socket(Connection2),
        {ok, FD2} = inet:getfd(Socket2),
        splicer:splice(FD1, FD2)
    end),
    {ok, _} = libp2p_connection:controlling_process(Connection1, Pid),
    {ok, _} = libp2p_connection:controlling_process(Connection2, Pid),
    Pid ! control_given,
    lager:info("spice started @ ~p", [Pid]),
    ok.

-spec proxy_successful(binary(), string(), pid(), string(), pid()) -> ok.
proxy_successful(ID, ServerMA, ServerStream, ClientMA, ClientStream) ->
    CProxyResp = libp2p_proxy_resp:create(true, ServerMA),
    SProxyResp = libp2p_proxy_resp:create(true, ClientMA),
    CEnv = libp2p_proxy_envelope:create(ID, CProxyResp),
    SEnv = libp2p_proxy_envelope:create(ID, SProxyResp),
    ServerStream ! {transfer, libp2p_proxy_envelope:encode(SEnv)},
    ClientStream ! {transfer, libp2p_proxy_envelope:encode(CEnv)},
    ok.

-spec get_id(binary(), map()) -> binary().
get_id(ID, Data) ->
    case maps:is_key(reverse_id(ID), Data) of
        true -> reverse_id(ID);
        false -> ID
    end.

-spec reverse_id(binary()) -> binary().
reverse_id(ID) ->
    binary:encode_unsigned(binary:decode_unsigned(ID, little), big).
