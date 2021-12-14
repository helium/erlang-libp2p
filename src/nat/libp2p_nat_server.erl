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
    start_link/1,
    register/4
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
    transport_tcp :: pid() | undefined,
    internal_address :: string() | undefined,
    internal_port :: integer() | undefined,
    external_address :: string() | undefined,
    external_port :: integer() | undefined,
    lease :: integer() | infinity | undefined,
    since :: integer() | undefined
}).

-define(CACHE_KEY, nat_external_port).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(TID) ->
    gen_server:start_link(reg_name(TID), ?MODULE, [TID], []).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
register(TID, TransportPid, MultiAddr, IntPort) ->
    case libp2p_config:lookup_nat(TID) of
        false ->
            {error, no_nat_server};
        {ok, Pid} ->
            gen_server:call(Pid, {register, TransportPid, MultiAddr, IntPort})
    end.


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID]=_Args) ->
    lager:info("~p init with ~p", [?MODULE, _Args]),
    true = libp2p_config:insert_nat(TID, self()),
    {ok, #state{tid=TID}}.

handle_call({register, TransportPid, MultiAddr, IntPort}, _From, #state{tid=TID, transport_tcp=undefined}=State) ->
    CachedExtPort = get_port_from_cache(TID, IntPort),
    ok = delete_mapping(IntPort, CachedExtPort),
    lager:info("using int port ~p ext port ~p ", [IntPort, CachedExtPort]),
    case libp2p_nat:add_port_mapping(IntPort, CachedExtPort) of
        {ok, ExtAddr, ExtPort, Lease, Since} ->
            ok = update_cache(TID, ExtPort),
            ok = nat_discovered(TransportPid, MultiAddr, ExtAddr, ExtPort),
            ok = renew(Lease),
            lager:info("added port mapping ~p", [{ExtAddr, ExtPort, Lease, Since}]),
            _Ref = erlang:monitor(process, TransportPid),
            {reply, ok, State#state{transport_tcp=TransportPid, internal_address=MultiAddr, internal_port=IntPort,
                                    external_address=ExtAddr, external_port=ExtPort, lease=Lease, since=Since}};
        {error, _Reason1} ->
            lager:info("failed to add port (~p) mapping with upnp: ~p", [{IntPort, CachedExtPort}, _Reason1]),
            {reply, {error, _Reason1}, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(renew, #state{transport_tcp=undefined}=State) ->
    lager:debug("got old renew ignoring"),
    {noreply, State};
handle_info(renew, #state{tid=TID, transport_tcp=Pid, internal_address=IntAddr, internal_port=IntPort,
                          external_address=ExtAddr0, external_port=ExtPort0}=State) ->
    case libp2p_nat:renew_port_mapping(IntPort, ExtPort0) of
        {ok, ExtAddr1, ExtPort1, Lease, Since} ->
            lager:info("renewed lease for ~p:~p (~p) for ~p seconds", [ExtAddr1, ExtPort1, IntPort, Lease]),
            ok = update_cache(TID, ExtPort1),
            ok = renew(Lease),
            case ExtPort0 =/= ExtPort1 orelse ExtAddr0 =/= ExtAddr1 of
                false -> ok;
                true ->
                    lager:info("address or port change ~p ~p", [{ExtAddr0, ExtAddr1}, {ExtPort0, ExtPort1}]),
                    ok = remove_multi_addr(TID, ExtAddr0, ExtPort0),
                    ok = nat_discovered(Pid, IntAddr, ExtAddr1, ExtPort1)
            end,
            {noreply, State#state{external_address=ExtAddr1, external_port=ExtPort1, lease=Lease, since=Since}};
        {error, _Reason} ->
            %% this might lead to a period of undialability
            ok = remove_multi_addr(TID, ExtAddr0, ExtPort0),
            lager:warning("failed to renew lease for port ~p: ~p", [{IntPort, ExtPort0}, _Reason]),
            Pid ! no_nat,
            _ = erlang:send_after(timer:minutes(5), self(), renew),
            {noreply, State}
    end;
handle_info({'DOWN', _Ref, process, TransportPid, Reason}, #state{internal_port=IntPort, external_port=ExtPort}=State) ->
    lager:warning("tcp transport ~p went down: ~p cleaning up", [TransportPid, Reason]),
    ok = delete_mapping(IntPort, ExtPort),
    {noreply, State#state{transport_tcp=undefined, internal_address=undefined, internal_port=undefined,
                          external_address=undefined, external_port=undefined, lease=undefined, since=undefined}};
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
-spec get_port_from_cache(ets:tab(), non_neg_integer()) -> non_neg_integer().
get_port_from_cache(TID, IntPort) ->
    Cache = libp2p_swarm:cache(TID),
    try libp2p_cache:lookup(Cache, ?CACHE_KEY) of
        undefined -> IntPort;
        0 -> IntPort; %% 0 is not valid
        P ->
            lager:info("got port from cache ~p", [P]),
            P
    catch _:_ ->
            IntPort
    end.

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
    {ok, ParsedExtAddr} = inet_parse:address(ExtAddr),
    ExtMultiAddr = libp2p_transport_tcp:to_multiaddr({ParsedExtAddr, ExtPort}),
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
update_cache(_TID, 0) ->
    ok; %% 0 is not valid
update_cache(TID, Port) ->
    Cache = libp2p_swarm:cache(TID),
    spawn(fun() ->
                  ok = libp2p_cache:insert(Cache, ?CACHE_KEY, Port)
          end),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% TODO: calculate more accurate time using since
%% @end
%%--------------------------------------------------------------------
-spec renew(integer() | infinity) -> ok.
renew(infinity) ->
    lager:info("not renewing lease is infinite");
renew(0) ->
    lager:info("not renewing lease is infinite");
renew(Time0) ->
    % Try to renew before so we don't have down time. Ensure at least 60 seconds
    % apart
    Time1 = max(timer:seconds(60), timer:seconds(Time0)-500),
    _ = erlang:send_after(Time1, self(), renew),
    lager:info("renewing lease in ~pms", [Time1]).
