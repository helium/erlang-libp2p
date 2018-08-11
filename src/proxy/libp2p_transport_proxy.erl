-module(libp2p_transport_proxy).

-behavior(libp2p_transport).

-export([
    start_link/1
    ,start_listener/2
    ,match_addr/1
    ,priority/0
    ,connect/5
]).

%% ------------------------------------------------------------------
%% libp2p_transport
%% ------------------------------------------------------------------
-spec start_link(ets:tab()) -> ignore.
start_link(_TID) ->
    ignore.

-spec start_listener(pid(), string()) -> {error, unsupported}.
start_listener(_Pid, _Addr) ->
    {error, unsupported}.

-spec match_addr(string()) -> false.
match_addr(Addr) when is_list(Addr) ->
    false.

-spec priority() -> integer().
priority() -> 99.

-spec connect(pid(), string(), libp2p_swarm:connect_opts()
              ,pos_integer(), ets:tab()) -> {ok, pid()}
                                            | {ok, pid(), any()}
                                            | {error, term()}.
connect(_Pid, MAddr, Options, Timeout, TID) ->
    {ok, {RAddress, AAddress}} = libp2p_relay:p2p_circuit(MAddr),
    true = libp2p_proxy:reg_addr(AAddress, self()),
    lager:info("init proxy with ~p", [[MAddr, RAddress, AAddress]]),

    ProxyOpts = [{unique_session, true}, {unique_port, true}],
    case libp2p_transport:connect_to(RAddress, Options ++ ProxyOpts, Timeout, TID) of
        {error, _Reason}=Error ->
            Error;
        {ok, SessionPid} ->
            Swarm = libp2p_swarm:swarm(TID),
            {ok, _} = libp2p_proxy:dial_framed_stream(
                Swarm
                ,RAddress
                ,[{destination, AAddress}]
            ),
            receive
                {proxy_negotiated} ->
                    libp2p_proxy:unreg_addr(AAddress),
                    {ok, SessionPid}
            after 8000 ->
                libp2p_proxy:unreg_addr(AAddress),
                {error, timeout_relay_session}
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
