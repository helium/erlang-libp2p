-module(libp2p_transport_proxy).

-behavior(libp2p_transport).

-export([
    start_link/1,
    start_listener/2,
    match_addr/2,
    sort_addrs/1,
    connect/5
]).

-define(PROXIES, proxies).

%% ------------------------------------------------------------------
%% libp2p_transport
%% ------------------------------------------------------------------
-spec start_link(ets:tab()) -> ignore.
start_link(_TID) ->
    ignore.

-spec start_listener(pid(), string()) -> {error, unsupported}.
start_listener(_Pid, _Addr) ->
    {error, unsupported}.

-spec match_addr(string(), ets:tab()) -> false.
match_addr(Addr, _TID) when is_list(Addr) ->
    false.

-spec sort_addrs([string()]) -> [{integer(), string()}].
sort_addrs(Addrs) ->
    [{5, A} || A <- Addrs].

-spec connect(pid(), string(), libp2p_swarm:connect_opts(),
              pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect(Pid, MAddr, Options, Timeout, TID) ->
    {ok, {PAddress, AAddress}} = libp2p_relay:p2p_circuit(MAddr),
    lager:info("init proxy with ~p", [[PAddress, AAddress]]),
    case erlang:get(?PROXIES) of
        undefined ->
            _ = erlang:put(?PROXIES, [AAddress]),
            connect_to(Pid, MAddr, Options, Timeout, TID, PAddress, AAddress);
        Proxies ->
            case lists:member(PAddress, Proxies) of
                true ->
                    {error, proxy_loop};
                false ->
                    _ = erlang:put(?PROXIES, [AAddress|Proxies]),
                    connect_to(Pid, MAddr, Options, Timeout, TID, PAddress, AAddress)
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec connect_to(pid(), string(), libp2p_swarm:connect_opts(), pos_integer(),
                 ets:tab(), string(), string()) -> {ok, pid()} | {error, term()}.
connect_to(Pid, MAddr, Options, Timeout, TID, PAddress, AAddress) ->
    Swarm = libp2p_swarm:swarm(TID),
    ID = crypto:strong_rand_bytes(16),
    Args = [
        {p2p_circuit, MAddr},
        {transport, self()},
        {id, ID}
    ],
    case libp2p_proxy:dial_framed_stream(Swarm, PAddress, Args) of
        {error, _Reason} ->
            lager:error("failed to dial proxy server ~p ~p", [PAddress, _Reason]),
            {error, fail_dial_proxy};
        {ok, Stream} ->
            erlang:monitor(process, Stream),
            connect_rcv(Pid, MAddr, Options, Timeout, TID, PAddress, AAddress, Stream, Swarm)
    end.

-spec peer_for(pid(), string()) -> {ok, libp2p_peer:peer()} | {error, any()}.
peer_for(Swarm, Address) ->
    Peerbook = libp2p_swarm:peerbook(Swarm),
    PubKeyBin = libp2p_crypto:p2p_to_pubkey_bin(Address),
    libp2p_peerbook:get(Peerbook, PubKeyBin).

-spec connect_rcv(pid(), string(), libp2p_swarm:connect_opts(), pos_integer(),
                  ets:tab(), string(), string(), pid(), pid()) -> {ok, pid()} | {error, term()}.
connect_rcv(Pid, MAddr, Options, Timeout, TID, PAddress, AAddress, Stream, Swarm) ->
    receive
        {error, limit_exceeded} ->
            lager:warning("got error limit_exceeded proxying to ~p", [PAddress]),
            case peer_for(Swarm, AAddress) of
                {error, _Reason}=Error ->
                    lager:warning("peer_for failed ~p", [_Reason]),
                    Error;
                {ok, Peer} ->
                    ListenAddresses = lists:filter(
                        fun(A) -> A =/= MAddr end,
                        libp2p_peer:listen_addrs(Peer)
                    ),
                    lager:debug("ListenAddresses ~p", [ListenAddresses]),
                    case ListenAddresses of
                        [] ->
                            {error, limit_exceeded};
                        [Address|_] ->
                            libp2p_swarm:connect(Pid, Address, Options, Timeout)
                    end
            end;
        {error, _Reason}=Error ->
            lager:warning("proxy failed ~p", [_Reason]),
            Error;
        {proxy_negotiated, Socket, MultiAddr} ->
            Conn = libp2p_transport_tcp:new_connection(Socket, MultiAddr),
            lager:info("proxy successful ~p", [Conn]),
            libp2p_transport:start_client_session(TID, MAddr, Conn);
        {'DOWN', _Ref, process, Stream, _Reason} ->
            lager:error("stream ~p went down ~p", [Stream, _Reason]),
            {error, stream_down}
    after 15000 ->
        lager:warning("timeout_proxy_session proxying to ~p", [PAddress]),
        {error, timeout_proxy_session}
    end.
