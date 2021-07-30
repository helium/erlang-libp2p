%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p NAT ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_nat).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    enabled/1
    ,maybe_spawn_discovery/3, spawn_discovery/3
    ,add_port_mapping/2
    ,maybe_apply_nat_map/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type opt() :: {enabled, boolean()}.
-export_type([opt/0]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec enabled(ets:tab() | list()) -> boolean().
enabled(Opts) when is_list(Opts) ->
    libp2p_config:get_opt(Opts, [?MODULE, enabled], true);
enabled(TID) ->
    Opts = libp2p_swarm:opts(TID),
    libp2p_config:get_opt(Opts, [?MODULE, enabled], true).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_spawn_discovery(pid(), [string()], ets:tab()) -> ok.
maybe_spawn_discovery(Pid, MultiAddrs, TID) ->
    case ?MODULE:enabled(TID) of
        true ->
            erlang:spawn(?MODULE, spawn_discovery, [Pid, MultiAddrs, TID]),
            ok;
        false ->
            lager:warning("nat is disabled")
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec spawn_discovery(pid(), [string()], ets:tab()) -> ok.
spawn_discovery(Pid, MultiAddrs, _TID) ->
    case lists:filtermap(fun discovery_filter/1, MultiAddrs) of
        [] -> ok;
        [{MultiAddr, _IP, Port}|_] ->
            lager:info("trying to map ~p ~p", [MultiAddr, Port]),
            %% TODO we should make a port mapping for EACH address
            %% here, for weird multihomed machines, but natupnp_v1 and
            %% natpmp don't support issuing a particular request from
            %% a particular interface yet
            {ok, Statem} = libp2p_nat_statem:start([Pid]),
            case add_port_mapping(Port, true) of
                {ok, ExtAddr, ExtPort, Lease, Since} ->
                    _ = libp2p_nat_statem:register(Statem, ExtPort, Lease, Since),
                    {ok, ParsedExtAddress} = inet_parse:address(ExtAddr),
                    ExtMultiAddr = libp2p_transport_tcp:to_multiaddr({ParsedExtAddress, ExtPort}),
                    Pid ! {nat_discovered, MultiAddr, ExtMultiAddr},
                    ok;
                {error, _Reason} ->
                    lager:warning("unable to add nat mapping: ~p", [_Reason])
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_port_mapping(integer(), boolean()) ->
    {ok, string(), integer(), integer(), integer()} | {error, any()}.
add_port_mapping(Port, false) ->
    case nat:discover() of
        {ok, Context} ->
            MaxRetry = erlang:length(retry_matrix(Port)),
            add_port_mapping(Context, Port, MaxRetry);
        no_nat ->
            {error, no_nat}
    end;
add_port_mapping(Port, true) ->
    case nat:discover() of
        {ok, Context} ->
            case nat:delete_port_mapping(Context, tcp, Port, Port) of
                ok -> ok;
                {error, _Reason} ->
                    lager:warning("failed to delete port mapping ~p: ~p", [Port, _Reason])
            end,
            MaxRetry = erlang:length(retry_matrix(Port)),
            add_port_mapping(Context, Port, MaxRetry);
        no_nat ->
            {error, no_nat}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
maybe_apply_nat_map({IP, Port}) ->
    Map = application:get_env(libp2p, nat_map, #{}),
    case maps:get({IP, Port}, Map, maps:get(IP, Map, {IP, Port})) of
        {NewIP, NewPort} ->
            {NewIP, NewPort};
        NewIP ->
            {NewIP, Port}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec discovery_filter(string()) -> false | {true, any()}.
discovery_filter(MultiAddr) ->
    case libp2p_transport_tcp:tcp_addr(MultiAddr) of
        {IP, Port, inet, _} ->
            case libp2p_transport_tcp:rfc1918(IP) of
                false -> false;
                _ -> {true, {MultiAddr, IP, Port}}
            end;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_port_mapping(nat:nat_ctx(), integer(), integer()) ->
    {ok, string(), integer(), integer(), integer()} | {error, any()}.
add_port_mapping(_Context, _Port, 0) ->
    {error, too_many_retries};
add_port_mapping(Context, Port, Retry) ->
    {Lease0, ExtPort} = retry_matrix(Retry, Port),
    case nat:add_port_mapping(Context, tcp, Port, ExtPort, Lease0) of
        {ok, Since, Port, ExtPort, Lease1} ->
            {ok, ExternalAddress} = nat:get_external_address(Context),
            {ok, ExternalAddress, ExtPort, Lease1, Since};
        {error, _Reason} ->
            lager:warning("failed to add port mapping for ~p: ~p", [{ExtPort, Lease0}, _Reason]),
            add_port_mapping(Context, Port, Retry-1)
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec retry_matrix(integer()) -> list().
retry_matrix(Port) ->
    [
        {0, Port}
        ,{60*60*24, Port}
        ,{60*60, Port}
        ,{0, increment_port(Port)}
        ,{0, random_port(Port)}
        ,{60*60*24, increment_port(Port)}
        ,{60*60*24, random_port(Port)}
        ,{60*60, increment_port(Port)}
        ,{60*60, random_port(Port)}
    ].

-spec retry_matrix(integer(), integer()) -> {integer(), integer()}.
retry_matrix(Try, Port) ->
    lists:nth(Try, retry_matrix(Port)).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
increment_port(Port) when Port < 65535-1 ->
    Port+1.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec random_port(integer()) -> integer().
random_port(Port) ->
    case rand:uniform(65535-1024) + 1024 of
        Port -> random_port(Port);
        RandomPort -> RandomPort
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

nat_map_test() ->
    application:load(libp2p),
    %% no nat map, everything is unchanged
    ?assertEqual({{192,168,1,10}, 1234}, maybe_apply_nat_map({{192,168,1,10}, 1234})),
    application:set_env(libp2p, nat_map, #{
                                  {192, 168, 1, 10} => {67, 128, 3, 4},
                                  {{192, 168, 1, 10}, 4567} => {67, 128, 3, 99},
                                  {192, 168, 1, 11} => {{67, 128, 3, 4}, 1111}
                                 }),
    ?assertEqual({{67,128,3,4}, 1234}, maybe_apply_nat_map({{192,168,1,10}, 1234})),
    ?assertEqual({{67,128,3,99}, 4567}, maybe_apply_nat_map({{192,168,1,10}, 4567})),
    ?assertEqual({{67,128,3,4}, 1111}, maybe_apply_nat_map({{192,168,1,11}, 4567})),
    ok.

-endif.
