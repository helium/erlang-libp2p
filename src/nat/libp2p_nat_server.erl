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
    tid :: ets:tab(),
    transport_tcp :: pid(),
    internal_address :: string(),
    internal_port :: integer() | undefined,
    external_address :: string() | undefined,
    external_port :: integer() | undefined,
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
init([Pid, TID, MultiAddr, InternalPort]=_Args) ->
    lager:info("init with ~p", [_Args]),
    true = erlang:link(Pid),
    self() ! post_init,
    {ok, #state{tid=TID, transport_tcp=Pid, internal_address=MultiAddr, internal_port=InternalPort}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{tid=TID, transport_tcp=Pid, internal_address=MultiAddr, internal_port=IntPort}=State) ->
    Cache = libp2p_swarm:cache(TID),
    CachedExtPort =
        case libp2p_cache:lookup(Cache, ?CACHE_KEY) of
            undefined -> IntPort;
            P ->
                lager:info("got port from cache ~p", [P]),
                P
        end,
    lager:info("using int port ~p ext port ~p ", [IntPort, CachedExtPort]),
    case libp2p_nat:delete_port_mapping(IntPort, CachedExtPort) of
        {error, _Reason0} -> lager:warning("failed to delete port mapping ~p: ~p", [{IntPort, CachedExtPort}, _Reason0]);
        ok -> ok
    end,
    case libp2p_nat:add_port_mapping(IntPort, CachedExtPort) of
        {ok, ExtAddr, ExtPort, Lease, Since} ->
            lager:info("added port mapping ~p", [{ExtAddr, ExtPort, Lease, Since}]),
            ok = update_cache(TID, ExtPort),
            ok = nat_discovered(Pid, MultiAddr, ExtAddr, ExtPort),
            case Lease =/= 0 of
                true -> ok = renew(Lease);
                false -> ok
            end,
            {noreply, State#state{external_address=ExtAddr, external_port=ExtPort, lease=Lease, since=Since}};
        {error, _Reason1} ->
            {stop, init_port_mapping_failed}
    end;
handle_info(renew, #state{tid=TID, transport_tcp=Pid, internal_address=MultiAddr, internal_port=IntPort,
                          external_address=ExtAddress0, external_port=ExtPort0}=State) ->
    case libp2p_nat:add_port_mapping(IntPort, ExtPort0) of
        {ok, ExtAddress1, ExtPort1, Lease, Since} ->
            lager:info("renewed lease for ~p:~p (~p) for ~p seconds", [ExtAddress1, ExtPort1, IntPort, Lease]),
            ok = update_cache(TID, ExtPort1),
            ok = renew(Lease),
            case ExtPort0 =/= ExtPort1 of
                false -> ok;
                true ->
                    lager:info("deleting old port mapping for ~p", [{IntPort, ExtPort0}]),
                    ok = delete_mapping(IntPort, ExtPort0)
            end,
            case ExtPort0 =/= ExtPort1 orelse ExtAddress0 =/= ExtAddress1 of
                false -> ok;
                true ->
                    lager:info("address or port change ~p ~p", [{ExtAddress0, ExtAddress1}, {ExtPort0, ExtPort1}]),
                    ok = remove_multi_addr(TID, ExtAddress0, ExtPort0),
                    ok = nat_discovered(Pid, MultiAddr, ExtAddress1, ExtPort1)
            end,
            {noreply, State#state{external_address=ExtAddress1, external_port=ExtPort1, lease=Lease, since=Since}};
        {error, _Reason} ->
            lager:warning("failed to renew lease for port ~p: ~p", [{IntPort, ExtPort0}, _Reason]),
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
-spec delete_mapping(integer(), integer()) -> ok.
delete_mapping(IntPort, ExtPort) ->
    case libp2p_nat:delete_port_mapping(IntPort, ExtPort) of
        ok ->
            ok;
        {error, _Reason} ->
            lager:warning("failed to delete port mapping ~p: ~p", [{IntPort, ExtPort}, _Reason])
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
