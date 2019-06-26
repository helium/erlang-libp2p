%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p NAT Server ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_nat_server).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1
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
    transport_tcp :: pid(),
    internal_address :: string(),
    tid :: ets:tab(),
    address :: string() | undefined,
    port :: integer() | undefined,
    lease :: integer() | undefined,
    since :: integer() | undefined
}).

-define(CACHE_KEY, nat_external_port).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start(Args) ->
    gen_server:start(?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Pid, TID, MultiAddr, Port]=_Args) ->
    lager:info("init with ~p", [_Args]),
    true = erlang:link(Pid),
    self() ! post_init,
    {ok, #state{transport_tcp=Pid, tid=TID, internal_address=MultiAddr, port=Port}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{transport_tcp=Pid, tid=TID, internal_address=MultiAddr, port=Port}=State) ->
    Cache = libp2p_swarm:cache(TID),
    CachedPort =
        case libp2p_cache:lookup(Cache, ?CACHE_KEY) of
            undefined -> Port;
            P ->
                lager:info("got port from cache ~p", [P]),
                P
        end,
    lager:info("using port ~p", [CachedPort]),
    case libp2p_nat:delete_port_mapping(CachedPort) of
        {error, _Reason0} -> lager:warning("failed to delete port mapping ~p: ~p", [CachedPort, _Reason0]);
        ok -> ok
    end,
    case libp2p_nat:add_port_mapping(CachedPort) of
        {ok, ExtAddr, ExtPort, Lease, Since} ->
            lager:info("added port mapping ~p", [{ExtAddr, ExtPort, Lease, Since}]),
            ok = update_cache(TID, ExtPort),
            ok = nat_discovered(Pid, MultiAddr, ExtAddr, ExtPort),
            case Lease =/= 0 of
                true -> ok = renew(Lease);
                false -> ok
            end,
            {noreply, State#state{address=ExtAddr, port=ExtPort, lease=Lease, since=Since}};
        {error, _Reason1} ->
            {stop, init_port_mapping_failed}
    end;
handle_info(renew, #state{transport_tcp=Pid, address=Address, port=Port, tid=TID, internal_address=MultiAddr}=State) ->
    case libp2p_nat:add_port_mapping(Port) of
        {ok, ExtAddr, ExtPort, Lease, Since} ->
            lager:info("renewed lease for ~p:~p (~p) for ~p seconds", [ExtAddr, ExtPort, Port, Lease]),
            ok = update_cache(TID, ExtPort),
            ok = renew(Lease),
            case Port =/= ExtPort of
                false -> ok;
                true ->
                    lager:info("deleting old port mapping for ~p", [Port]),
                    ok = delete_mapping(Port)
            end,
            case Port =/= ExtPort orelse Address =/= ExtAddr of
                false -> ok;
                true ->
                    lager:info("address or port change ~p ~p", [{Address, ExtAddr}, {Port, ExtPort}]),
                    ok = remove_multi_addr(TID, Address, Port),
                    ok = nat_discovered(Pid, MultiAddr, ExtAddr, ExtPort)
            end,
            {noreply, State#state{address=ExtAddr, port=ExtPort, lease=Lease, since=Since}};
        {error, _Reason} ->
            lager:warning("failed to renew lease for port ~p: ~p", [Port, _Reason]),
            {stop, renew_failed}
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

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec remove_multi_addr(ets:tab(), string(), non_neg_integer()) -> ok.
remove_multi_addr(TID, Address, Port) ->
    {ok, ParsedAddress} = inet_parse:address(Address),
    MultiAddr = libp2p_transport_tcp:to_multiaddr({ParsedAddress, Port}),
    true = libp2p_config:remove_listener(TID, MultiAddr),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec nat_discovered(pid(), string(), string(), non_neg_integer()) -> ok.
nat_discovered(Pid, MultiAddr, ExtAddr, ExtPort) ->
    {ok, ParsedExtAddress} = inet_parse:address(ExtAddr),
    ExtMultiAddr = libp2p_transport_tcp:to_multiaddr({ParsedExtAddress, ExtPort}),
    Pid ! {nat_discovered, MultiAddr, ExtMultiAddr},
    ok.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec delete_mapping(non_neg_integer()) -> ok.
delete_mapping(Port) ->
    case libp2p_nat:delete_port_mapping(Port) of
        ok ->
            ok;
        {error, _Reason} ->
            lager:warning("failed to delete port mapping ~p: ~p", [Port, _Reason])
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec update_cache(ets:tab(), non_neg_integer()) -> ok.
update_cache(TID, Port) ->
    Cache = libp2p_swarm:cache(TID),
    ok = libp2p_cache:insert(Cache, ?CACHE_KEY, Port).

%%--------------------------------------------------------------------
%% @doc
%% TODO: calculate more accurate time using since
%% @end
%%--------------------------------------------------------------------
-spec renew(integer()) -> ok.
renew(0) ->
    ok;
renew(Time) when Time > 2000 ->
    _ = erlang:send_after(timer:seconds(Time)-2000, self(), renew),
    ok;
renew(Time) ->
    _ = erlang:send_after(timer:seconds(Time), self(), renew),
    ok.
