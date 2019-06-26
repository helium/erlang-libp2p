-module(nat_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic/1,
    server/1
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
    [basic, server].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_, _Config) ->
    test_util:setup(),
    lager:set_loglevel(lager_console_backend, info),
    _Config.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    {ok, Swarm} = libp2p_swarm:start(nat_basic),

    start_tracing(self()),

    [] = libp2p_swarm:listen_addrs(Swarm),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

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
    ),
    ok = dbg:stop(),
    libp2p_swarm:stop(Swarm).

server(_Config) ->
    Self = self(),
    MockLease = 3,
    Since = 0,

    meck:new(nat, [no_link, passthrough]),
    meck:expect(nat, discover, fun() ->
        {ok, context}
    end),
    meck:expect(nat, add_port_mapping, fun(_Context, tcp, _Port, _ExtPort, 0) ->
        {error, error};
                                          (_Context, tcp, Port, ExtPort, _Lease) ->
        {ok, Since, Port, ExtPort, MockLease}
    end),
    meck:expect(nat, get_external_address, fun(_Context) ->
        {ok, "127.0.0.1"}
    end),
    meck:expect(nat, delete_port_mapping, fun(_Context, tcp, _Port, _Port) ->
        ok
    end),

    meck:new(libp2p_nat_server, [no_link, passthrough]),
    meck:expect(libp2p_nat_server, start, fun(Args) ->
        {ok, Pid} = gen_server:start(libp2p_nat_server, Args, []),
        erlang:trace(Pid, true, [{tracer, Self}, 'receive']),
        {ok, Pid}
    end),

    {ok, Swarm} = libp2p_swarm:start(nat_server),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

    server_rcv(MockLease, Since),

    ?assert(meck:validate(nat)),
    meck:unload(nat),
    ?assert(meck:validate(libp2p_nat_server)),
    meck:unload(libp2p_nat_server),

    libp2p_swarm:stop(Swarm).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
server_rcv(MockLease, Since) ->
    receive
        {trace, _, 'receive', renew} ->
            ok;
        {trace, _, 'receive', post_init} ->
            server_rcv(MockLease, Since);
        {trace, _, 'receive', _} ->
            server_rcv(MockLease, Since);
        M ->
            ct:fail(M)
    after 4000 ->
        ct:fail(timeout)
    end.

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
