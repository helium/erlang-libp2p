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
    maybe_spawn_discovery/3, spawn_discovery/3
    ,maybe_apply_nat_map/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_spawn_discovery(pid(), [string()], ets:tab()) -> ok.
maybe_spawn_discovery(Pid, MultiAddrs, TID) ->
    Opts = libp2p_swarm:opts(TID),
    case libp2p_config:get_opt(Opts, [?MODULE, nat], true) of
        true ->
            erlang:spawn(?MODULE, spawn_discovery, [Pid, MultiAddrs, TID]),
            ok;
        _ ->
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
            %% TODO we should make a port mapping for EACH address
            %% here, for weird multihomed machines, but natupnp_v1 and
            %% natpmp don't support issuing a particular request from
            %% a particular interface yet
            case add_port_mapping(Port) of
                {ok, ExternalAddr} ->
                    {ok, ParsedExtAddress} = inet_parse:address(ExternalAddr),
                    ExternalMultiAddr = libp2p_transport_tcp:to_multiaddr({ParsedExtAddress, Port}),
                    Pid ! {nat_discovery, MultiAddr, ExternalMultiAddr},
                    ok;
                {error, _Reason} ->
                    lager:warning("unable to add nat mapping: ~p", [_Reason])
            end
    end.

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

-spec add_port_mapping(integer()) -> {ok, string()} | {error, any()}.
add_port_mapping(Port) ->
    case nat:discover() of
        {ok, Context} ->
            case nat:add_port_mapping(Context, tcp, Port, Port, 0) of
                {ok, _Since, Port, Port, _MappingLifetime} ->
                    ExternalAddress = nat:get_external_address(Context),
                    {ok, ExternalAddress};
                {error, _Reason}=Error ->
                    Error
            end;
        no_nat ->
            {error, no_nat}
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
