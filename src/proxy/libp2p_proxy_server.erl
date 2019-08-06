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
    start_link/1,
    proxy/4,
    connection/3
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    tid :: ets:tab() | undefined,
    swarm :: pid() | undefined,
    data = maps:new() :: map(),
    limit :: integer(),
    size = 0 :: integer(),
    spliced = maps:new() :: map()
}).

-record(pstate, {
    id :: binary() | undefined,
    server_stream :: pid() | undefined,
    client_stream :: pid() | undefined,
    connections = [] :: [{{pid(), reference()}, libp2p_connection:connection()}],
    timeout :: reference()
}).

-define(SPLICE_TIMEOUT, timer:seconds(30)).

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
            lager:info("handling proxy connection ~p from ~p to ~p", [Connection, ID, Pid]),
            {ok, _} = libp2p_connection:controlling_process(Connection, Pid),
            gen_server:call(Pid, {connection, Connection, ID}, infinity)
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID, Limit]=Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?MODULE, Args]),
    true = libp2p_config:insert_proxy(TID, self()),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{tid=TID, swarm=Swarm, limit=Limit}}.

handle_call({init_proxy, ID, ServerStream, SAddress}, _From, #state{data=Data,
                                                                    limit=Limit,
                                                                    size=Size}=State) when Size < Limit ->
    PState = #pstate{
        id=ID,
        server_stream=ServerStream,
        % Timer is created just in case to decrease size if this is not cancelled in time
        timeout=erlang:send_after(timer:seconds(60), self(), {timeout, ID})
    },
    Data1 = maps:put(ID, PState, Data),
    self() ! {post_init, ID, SAddress},
    % We are starting to process proxy request size + 1
    {reply, ok, State#state{data=Data1, size=Size+1}};
handle_call({init_proxy, ID, _ServerStream, SAddress}, _From, #state{swarm=Swarm}=State) ->
    lager:warning("cannot process proxy request for ~p, ~p. Limit exceeded", [ID, SAddress]),
    erlang:spawn(
        fun() ->
            case libp2p_proxy:dial_framed_stream(Swarm, SAddress, [{id, ID}, {swarm, Swarm}]) of
                {ok, ClientStream} ->
                    Ref = erlang:monitor(process, ClientStream),
                    ClientStream ! proxy_overloaded,
                    receive
                        {'DOWN', Ref, process, ClientStream, _} ->
                            ok
                    after 10000 ->
                        ClientStream ! stop
                    end;
                _ ->
                    ok
            end
        end
    ),
    {reply, {error, limit_exceeded}, State};
handle_call({connection, Connection, ID0}, From, #state{data=Data, spliced=Spliced}=State) ->
    %% possibly reverse the ID if we got it from the client
    ID = get_id(ID0, Data),
    case maps:get(ID, Data, undefined) of
        undefined ->
            lager:warning("got unknown ID ~p closing ~p", [ID, Connection]),
            _ = libp2p_connection:close(Connection),
            {reply, ok, State};
        #pstate{connections=[]}=PState ->
            lager:info("got first Connection ~p", [Connection]),
            PState1 = PState#pstate{connections=[{From, Connection}]},
            {noreply, State#state{data=maps:put(ID, PState1, Data)}};
        #pstate{connections=[{From1, Connection1}|[]],
                server_stream=ServerStream,
                client_stream=ClientStream,
                timeout=TimerRef} ->
            % Cancelling timer
            _ = erlang:cancel_timer(TimerRef),
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
            {ok, Pid} = splice(From1, Connection1, From, Connection),
            ok = proxy_successful(ID, ServerMA, ServerStream, ClientMA, ClientStream),
            {noreply, State#state{data=maps:remove(ID, Data), spliced=maps:put(Pid, ID, Spliced)}}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({post_init, ID, SAddress}, #state{swarm=Swarm, data=Data, size=Size}=State) ->
    case maps:find(ID, Data) of
        {ok, PState} ->
            case libp2p_proxy:dial_framed_stream(Swarm, SAddress, [{id, ID}]) of
                {ok, ClientStream} ->
                    lager:info("dialed A (~p)", [SAddress]),
                    #pstate{id=ID, server_stream=ServerStream} = PState,
                    ok = dial_back(ID, ServerStream, ClientStream),
                    PState1 = PState#pstate{client_stream=ClientStream},
                    Data1 = maps:put(ID, PState1, Data),
                    {noreply, State#state{data=Data1}};
                _ ->
                    %% cancel the timeout timer
                    _ = erlang:cancel_timer(PState#pstate.timeout),
                    % If we can't dial client stream we should cleanup (size-1 and remove data)
                    {noreply, State#state{data=maps:remove(ID, Data), size=Size-1}}
            end;
        error ->
            lager:warning("Got unexpected post_init for ID ~p to ~p", [ID, SAddress]),
            {noreply, State}
    end;
handle_info({timeout, ID}, #state{data=Data, size=Size}=State) ->
    case maps:find(ID, Data) of
        {ok, _} ->
            % Client / Server did not dial back in time we are cleaning up
            lager:warning("~p timeout, did not dial back in time", [ID]),
            {noreply, State#state{size=Size-1, data=maps:remove(ID, Data)}};
        error ->
            lager:warning("Got unexpected timeout for ID ~p", [ID]),
            {noreply, State}
    end;
handle_info({'EXIT', Who, Reason}, #state{size=Size, spliced=Spliced}=State) ->
    % Exit now only cleanup if it knows about that Pid (splice process)
    case maps:is_key(Who, Spliced) of
        false ->
            {noreply, State};
        true ->
            lager:warning("splice process ~p went down: ~p", [Who, Reason]),
            {noreply, State#state{size=Size-1, spliced=maps:remove(Who, Spliced)}}
    end;
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

-spec splice(any(), libp2p_connection:connection(), any(), libp2p_connection:connection()) -> {ok, pid()}.
splice(From1, Connection1, From2, Connection2) ->
    Pid = erlang:spawn_link(
            fun() ->
                    try
                        receive control_given -> ok
                        after 10000 -> throw(control_transfer_timeout)
                        end,
                        Socket1 = libp2p_connection:socket(Connection1),
                        {ok, FD1} = inet:getfd(Socket1),
                        Socket2 = libp2p_connection:socket(Connection2),
                        {ok, FD2} = inet:getfd(Socket2),
                        splicer:splice(FD1, FD2, ?SPLICE_TIMEOUT)
                    catch _:E ->
                            lager:warning("splice worker exited with ~p", [E]),
                            ok
                    end,
                    (catch libp2p_connection:close(Connection1)),
                    (catch libp2p_connection:close(Connection2)),
                    gen_server:reply(From1, ok),
                    gen_server:reply(From2, ok)
            end),
    {ok, _} = libp2p_connection:controlling_process(Connection1, Pid),
    {ok, _} = libp2p_connection:controlling_process(Connection2, Pid),
    Pid ! control_given,
    lager:info("splice started @ ~p", [Pid]),
    {ok, Pid}.

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
