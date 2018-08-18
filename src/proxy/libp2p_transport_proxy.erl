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
              ,pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect(_Pid, MAddr, _Options, _Timeout, TID) ->
    {ok, {PAddress, AAddress}} = libp2p_relay:p2p_circuit(MAddr),
    lager:info("init proxy with ~p", [[PAddress, AAddress]]),
    Swarm = libp2p_swarm:swarm(TID),
    ID = crypto:strong_rand_bytes(16),
    Args = [
        {p2p_circuit, MAddr}
        ,{transport, self()}
        ,{id, ID}
    ],
    {ok, _} = libp2p_proxy:dial_framed_stream(
        Swarm
        ,PAddress
        ,Args
    ),
    receive
        {proxy_negotiated, Socket, MultiAddr} ->
            Conn = libp2p_transport_tcp:new_connection(Socket, MultiAddr),
            lager:info("proxy successful ~p", [Conn]),
            libp2p_transport:start_client_session(TID, MAddr, Conn)
    after 8000 ->
        {error, timeout_relay_session}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
