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
    ,maybe_apply_nat_map/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec enabled(ets:tab() | list()) -> boolean().
enabled(Opts) when is_list(Opts) ->
    libp2p_config:get_opt(Opts, [?MODULE, nat], true);
enabled(TID) ->
    Opts = libp2p_swarm:opts(TID),
    libp2p_config:get_opt(Opts, [?MODULE, nat], true).

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
            case add_port_mapping(Port) of
                {ok, ExternalAddr, _Lease} ->
                    {ok, ParsedExtAddress} = inet_parse:address(ExternalAddr),
                    ExternalMultiAddr = libp2p_transport_tcp:to_multiaddr({ParsedExtAddress, Port}),
                    Pid ! {nat_discovery, MultiAddr, ExternalMultiAddr},
                    ok;
                {error, _Reason} ->
                    lager:warning("unable to add nat mapping: ~p", [_Reason])
            end
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
-spec add_port_mapping(integer()) -> {ok, string(), integer()}
                                     | {error, any()}.
add_port_mapping(Port) ->
    add_port_mapping(Port, 3).

-spec add_port_mapping(integer(), integer()) -> {ok, string(), integer()}
                                                | {error, any()}.
add_port_mapping(_Port, 0) ->
    {error, too_many_retries};
add_port_mapping(Port, Retry) ->
    case nat:discover() of
        {ok, Context} ->
            Lease = retry_lease(Retry),
            case nat:add_port_mapping(Context, tcp, Port, Port, Lease) of
                {ok, _Since, Port, Port, _Lease} ->
                    {ok, ExternalAddress} = nat:get_external_address(Context),
                    {ok, ExternalAddress, Lease};
                {error, _Reason} ->
                    lager:warning("failed to add port mapping for ~p: ", [{Port, Lease}, _Reason]),
                    add_port_mapping(Port, Retry-1)
            end;
        no_nat ->
            {error, no_nat}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec retry_lease(integer()) -> integer().
retry_lease(3) -> 0;
retry_lease(2) -> 60*60*24;
retry_lease(1) -> 60*60.

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
