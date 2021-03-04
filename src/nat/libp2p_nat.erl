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
    enabled/1,
    maybe_spawn_discovery/3, spawn_discovery/3,
    add_port_mapping/2, delete_port_mapping/2,
    renew_port_mapping/2,
    maybe_apply_nat_map/1
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
spawn_discovery(Pid, MultiAddrs, TID) ->
    case lists:filtermap(fun discovery_filter/1, MultiAddrs) of
        [] -> ok;
        [{MultiAddr, _IP, Port}|_] ->
            lager:info("trying to map ~p ~p", [MultiAddr, Port]),
            %% TODO we should make a port mapping for EACH address
            %% here, for weird multihomed machines, but natupnp_v1 and
            %% natpmp don't support issuing a particular request from
            %% a particular interface yet
            case libp2p_nat_server:register(TID, Pid, MultiAddr, Port) of
                ok ->
                    lager:info("successfully registered nat");
                {error, _Reason} ->
                    lager:error("failed to register nat ~p", [_Reason])
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_port_mapping(integer(), integer()) ->
    {ok, string(), integer(), integer() | infinity, integer()} | {error, any()}.
add_port_mapping(InternalPort, ExternalPort) ->
    try
        case nat:discover() of
            {ok, Context} ->
                MaxRetry = erlang:length(retry_matrix(Context, ExternalPort)),
                add_port_mapping(Context, InternalPort, ExternalPort, MaxRetry);
            no_nat ->
                {error, no_nat}
        end
    of
        Result -> Result
    catch Type:Excep ->
        lager:error("failed to add port mapping ~p ~p", [Type, Excep]),
        {error, {Type, Excep}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec delete_port_mapping(integer(), integer()) -> ok | {error, any()}.
delete_port_mapping(InternalPort, ExternalPort) ->
    case nat:discover() of
        {ok, Context} ->
            nat:delete_port_mapping(Context, tcp, InternalPort, ExternalPort);
        no_nat ->
            {error, no_nat}
    end.

-spec renew_port_mapping(integer(), integer()) ->
    {ok, string(), integer(), integer() | infinity, integer()} | {error, any()}.
renew_port_mapping(InternalPort, ExternalPort) ->
    case nat:discover() of
        {ok, {natpmp, _}=_Context} ->
            %% A renewal packet is formatted identically to an
            %% initial mapping request packet, except that for renewals the client
            %% sets the Suggested External Port field to the port the gateway
            %% actually assigned, rather than the port the client originally wanted.
            add_port_mapping(InternalPort, ExternalPort);
        {ok, _Context} ->
            %nat:delete_port_mapping(Context, tcp, InternalPort, ExternalPort),
            add_port_mapping(InternalPort, ExternalPort);
        no_nat ->
            {error, no_nat}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
maybe_apply_nat_map({IP, Port}) ->
    Map0 = application:get_env(libp2p, nat_map, #{}),
    Map = maps:fold(fun(K, V, Acc) ->
                            try {maybe_parse(K), maybe_parse(V)} of
                                {K2, V2} ->
                                    maps:put(K2, V2, Acc)
                            catch
                                What:Why ->
                                    lager:warning("invalid nat map: ~p ~p ~p", [K, V, {What, Why}]),
                                Acc
                            end
                    end, #{}, Map0),
    case maps:get({IP, Port}, Map, maps:get(IP, Map, {IP, Port})) of
        {NewIP, NewPort} ->
            {NewIP, NewPort};
        NewIP ->
            {NewIP, Port}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

maybe_parse(IP) when is_tuple(IP), tuple_size(IP) == 4 ->
    IP;
maybe_parse({IP, Port}) when is_tuple(IP), tuple_size(IP) == 4, is_integer(Port) ->
    case Port of
        0 ->
            IP;
        _ ->
            {IP, Port}
    end;
maybe_parse(IPStr) when is_list(IPStr) ->
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    IP;
maybe_parse({IPStr, PortStr}) when is_list(IPStr), is_list(PortStr) ->
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    try list_to_integer(PortStr) of
        0 ->
            IP;
        Port ->
            {IP, Port}
    catch
        _:_ ->
            IP
    end.

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
-spec add_port_mapping(nat:nat_ctx(), integer(), integer(), integer()) ->
    {ok, string(), integer(), integer() | infinity, integer()} | {error, any()}.
add_port_mapping(_Context, _InternalPort, _ExternalPort, 0) ->
    {error, too_many_retries};
add_port_mapping(Context, InternalPort, ExternalPort0, Retry) ->
    {Lease0, ExternalPort1} = retry_matrix(Context, Retry, ExternalPort0),
    case nat:add_port_mapping(Context, tcp, InternalPort, ExternalPort1, Lease0) of
        {ok, Since, InternalPort, ExternalPort2, Lease1} ->
            {ok, ExternalAddress} = nat:get_external_address(Context),
            {ok, ParsedAddress} = inet:parse_address(ExternalAddress),
            case libp2p_transport_tcp:rfc1918(ParsedAddress) of
                false ->
                    {ok, ExternalAddress, ExternalPort2, Lease1, Since};
                _ ->
                    nat:delete_port_mapping(Context, tcp, InternalPort, ExternalPort2),
                    lager:warning("Double NAT detected"),
                    {error, double_nat}
            end;
        {error, Reason} ->
            lager:warning("failed to add port mapping for ~p: ~p", [{ExternalPort1, Lease0}, Reason]),
            add_port_mapping(Context, InternalPort, ExternalPort0, Retry-1)
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec retry_matrix(nat:nat_ctx(), integer()) -> list().
retry_matrix({Type, _}=_Context, Port) ->
    %% matrix is reversed because tries count down to 0
    [
        {60*60, random_port(Port)},
        {60*60, increment_port(Port)},
        {60*60*24, random_port(Port)},
        {60*60*24, increment_port(Port)}
    ] ++
    %% infinite leases are not supported in nat-pmp
    [{0, random_port(Port)} || Type /= natpmp ] ++
    [{0, increment_port(Port)} || Type /= natpmp ] ++
    [
        {60*60, Port},
        {60*60*24, Port}
    ] ++
    %% infinite leases are not supported in nat-pmp
    [{0, Port} || Type /= natpmp ].

-spec retry_matrix(nat:nat_ctx(), integer(), integer()) -> {integer(), integer()}.
retry_matrix(Context, Try, Port) ->
    %% matrix is reversed because tries count down to 0
    lists:nth(Try, retry_matrix(Context, Port)).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
increment_port(Port) when Port < 65535-1 ->
    Port+1;
increment_port(Port) ->
    Port.

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

retry_matrix_test() ->
    UPNPContext = {natupnp_v2, any},
    PMPContext = {natpmp, any},
    UPNPMatrix = retry_matrix(UPNPContext, 1234),
    PMPMatrix = retry_matrix(PMPContext, 1234),

    %% upnp allows infinite leases and we try those first
    ?assertEqual({0, 1234}, retry_matrix(UPNPContext, erlang:length(UPNPMatrix), 1234)),
    ?assertEqual({86400, 1234}, retry_matrix(UPNPContext, erlang:length(UPNPMatrix) - 1, 1234)),
    ?assertEqual({3600, 1234}, retry_matrix(UPNPContext, erlang:length(UPNPMatrix) - 2, 1234)),
    ?assertEqual({0, 1235}, retry_matrix(UPNPContext, erlang:length(UPNPMatrix) - 3, 1234)),

    %% PMP does not allow infinite leases, so start with 1 day
    ?assertEqual({86400, 1234}, retry_matrix(PMPContext, erlang:length(PMPMatrix), 1234)),
    ?assertEqual({3600, 1234}, retry_matrix(PMPContext, erlang:length(PMPMatrix) - 1, 1234)),

    %% assert no infinite times exist in the PMP matrix at all
    ?assertNot(lists:any(fun(T) -> T == 0 end, element(1, lists:unzip(PMPMatrix)))),
    ok.

-endif.
