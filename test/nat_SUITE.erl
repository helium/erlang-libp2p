-module(nat_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0
    ,groups/0
    ,init_per_testcase/2
    ,end_per_testcase/2
]).

-export([
    basic/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [{group, nat}].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Tests groups
%% @end
%%--------------------------------------------------------------------
groups() ->
    [{nat, [], [basic]}].


%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_, Config) ->
    test_util:setup(),
    {ok, Swarm} = libp2p_swarm:start(test),
    [{swarm, Swarm} | Config].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, Config) ->
    Swarm = proplists:get_value(swarm, Config),
    test_util:teardown_swarms([Swarm]).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(Config) ->
    Swarm = proplists:get_value(swarm, Config),

    start_tracing(self()),

    [] = libp2p_swarm:listen_addrs(Swarm),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/8333"),

    Traces = gather_traces([]),

    ct:pal("~p", [Traces]),

    lists:foreach(
        fun(Pid) ->
            L = lists:reverse(maps:get(Pid, Traces)),
            case lists:nth(1, L) of
                {natupnp_v1, discover, []} ->
                    ok;
                {natpmp, discover, []} ->
                    ok;
                {libp2p_nat, spawn_discovery, _, _} ->
                    handle_discovery(L, undefined);
                {natpmp, add_port_mapping, _} ->
                    handle_natpmp(L, undefined);
                {natupnp_v1, add_port_mapping, _} ->
                    handle_natupnp_v1(L, undefined);
                _ ->
                    ok
            end
        end
        ,maps:keys(Traces)
    ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_discovery(list(), any()) -> ok.
handle_discovery([], _Meta) -> ok;
handle_discovery([{libp2p_nat, spawn_discovery, [_, [Addr|_], _]}|Traces], _Meta) ->
    handle_discovery(Traces, Addr);
handle_discovery([{libp2p_transport_tcp, handle_info, [{nat_discovery, Addr, _ExtAddr}, _State]}|Traces], Addr) ->
    handle_discovery(Traces, Addr).

-spec handle_natpmp(list(), any()) -> ok.
handle_natpmp([], _Meta) -> ok;
handle_natpmp([{natpmp, add_port_mapping, [Addr, tcp, 8333, 8333, 3600]}|Traces], _Meta) ->
    handle_natpmp(Traces, Addr);
handle_natpmp([{libp2p_transport_tcp, nat_external_address, [natpmp, Addr]}|Traces], Addr) ->
    handle_natpmp(Traces, Addr);
handle_natpmp([{natpmp, get_external_address, [Addr]}|Traces], Addr) ->
    handle_natpmp(Traces, Addr).

-spec handle_natupnp_v1(list(), any()) -> ok.
handle_natupnp_v1([], _Meta) -> ok;
handle_natupnp_v1([{natupnp_v1, add_port_mapping, [{nat_upnp, A1, A2}, tcp, 8333, 8333, 3600]}|Traces], _Meta) ->
    handle_natupnp_v1(Traces, {A1, A2});

handle_natupnp_v1([{libp2p_transport_tcp, nat_external_address, [{natupnp_v1, {nat_upnp, A1, A2}}]}|Traces], {A1, A2}) ->
    handle_natupnp_v1(Traces, {A1, A2});
handle_natupnp_v1([{natupnp_v1, get_external_address, [{nat_upnp, A1, A2}]}|Traces], {A1, A2}) ->
    handle_natupnp_v1(Traces, {A1, A2}).

-spec start_tracing(pid()) -> ok.
start_tracing(To) ->
    HandlerFun = fun(Data, State) ->
        To ! Data,
        State
    end,
    HandlerSpec = {HandlerFun, ok},
    {ok, _} = dbg:tracer(process, HandlerSpec),
    {ok, _} = dbg:tpl(libp2p_transport_tcp, '_', '_', []),
    {ok, _} = dbg:tpl(libp2p_nat, '_', '_', []),
    {ok, _} = dbg:tpl(natpmp, '_', '_', []),
    {ok, _} = dbg:tpl(natupnp_v1, '_', '_', []),
    {ok, _} = dbg:p(all, [c]),
    ok.

-spec gather_traces(list()) -> map().
gather_traces(Acc) ->
    receive
        {trace, Pid, call, {libp2p_nat, spawn_discovery, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {libp2p_nat, add_port_mapping, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {libp2p_transport_tcp, handle_info, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {natupnp_v1, discover, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {natupnp_v1, add_port_mapping, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {natupnp_v1, get_external_address, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {natpmp, discover, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {natpmp, add_port_mapping, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        {trace, Pid, call, {natpmp, get_external_address, _}=Data} ->
            gather_traces([{Pid, Data}|Acc]);
        _Data ->
            gather_traces(Acc)
    after 500 ->
        lists:foldr(
            fun({Pid, Call}, Map) ->
                case maps:get(Pid, Map, 'undefined') of
                    'undefined' -> maps:put(Pid, [Call], Map);
                    [_|_]=L ->
                        maps:put(Pid, [Call|L], Map)
                end
            end
            ,maps:new()
            ,Acc
        )
    end.
