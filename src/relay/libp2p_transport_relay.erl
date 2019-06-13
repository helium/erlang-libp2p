-module(libp2p_transport_relay).

-behavior(libp2p_transport).

-export([
    start_link/1
    ,start_listener/2
    ,match_addr/2
    ,sort_addrs/1
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

-spec match_addr(string(), ets:tab()) -> {ok, string()} | false.
match_addr(Addr, TID) when is_list(Addr) ->
    Protocols = multiaddr:protocols(Addr),
   case match_protocols(Protocols) of
       {ok, _} = Result ->
           SwarmAddress = libp2p_crypto:bin_to_b58(libp2p_swarm:pubkey_bin(TID)),
           case Protocols of
               [{"p2p", SwarmAddress}|_] ->
                   lager:info("can't match a relay address for ourselves"),
                   false;
               _ ->
                   Result
           end;
       false -> false
   end.

-spec sort_addrs([string()]) -> [string()].
sort_addrs(Addrs) ->
    Addrs.

-spec priority() -> integer().
priority() -> 1.

-spec connect(pid(), string(), libp2p_swarm:connect_opts()
              ,pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect(Pid, MAddr, Options, Timeout, TID) ->
    Swarm = libp2p_swarm:swarm(TID),
    ListenAddresses = libp2p_swarm:listen_addrs(Swarm),
    case proplists:get_value(no_relay, Options, false) of
        true ->
            {error, relay_not_allowed};
        false ->
            case check_peerbook(TID, MAddr) of
                {error, _Reason} ->
                    %% don't blacklist here, the peerbook update might be coming
                    {error, not_in_peerbook};
                false ->
                    %% blacklist the relay address, it is stale
                    {ok, {_RAddress, SAddress}} = libp2p_relay:p2p_circuit(MAddr),
                    MarkedPeerAddr = libp2p_crypto:p2p_to_pubkey_bin(SAddress),
                    PeerBook = libp2p_swarm:peerbook(Swarm),
                    ok = libp2p_peerbook:blacklist_listen_addr(PeerBook, MarkedPeerAddr, MAddr),
                    {error, not_in_peerbook};
                true ->
                    case has_p2p_circuit(ListenAddresses) of
                        false ->
                            connect_to(Pid, MAddr, Options, Timeout, TID);
                        true ->
                            libp2p_transport_proxy:connect(Pid, MAddr, [no_relay|Options], Timeout, TID)
                    end
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec connect_to(pid(), string(), libp2p_swarm:connect_opts()
                 ,pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect_to(_Pid, MAddr, Options, Timeout, TID) ->
    {ok, {RAddress, SAddress}} = libp2p_relay:p2p_circuit(MAddr),
    true = libp2p_relay:reg_addr_sessions(SAddress, self()),
    lager:info("init relay with ~p", [[MAddr, RAddress, SAddress]]),
    case libp2p_transport:connect_to(RAddress, Options, Timeout, TID) of
        {error, _Reason}=Error ->
            Error;
        {ok, SessionPid} ->
            Swarm = libp2p_swarm:swarm(TID),
            {ok, _} = libp2p_relay:dial_framed_stream(
                Swarm,
                RAddress,
                [{type, {bridge_cr, MAddr}}]
            ),
            connect_rcv(Swarm, MAddr, SAddress, SessionPid)
    end.

-spec match_protocols(list()) -> {ok, string()} | false.
match_protocols(Protocols) ->
    match_protocols(Protocols, []).

-spec match_protocols(list(), list()) -> {ok, string()} | false.
match_protocols([], _Acc) ->
    false;
match_protocols([{"p2p-circuit", _} | _]=A, Acc) ->
    {ok, multiaddr:to_string(lists:reverse(Acc) ++ A)};
match_protocols([{_, _}=Head | Tail], Acc) ->
    match_protocols(Tail, [Head|Acc]).


-spec has_p2p_circuit(list()) -> boolean().
has_p2p_circuit(Addresses) ->
    lists:foldl(
        fun(_, true) ->
            true;
        (Address, _) ->
            libp2p_relay:is_p2p_circuit(Address)
        end
        ,false
        ,Addresses
    ).

%% returns true or false if the peerbook says this route is possible
%% returns an error if the peerbook doesn't contain the relay's entry
-spec check_peerbook(ets:tab(), string()) -> boolean() | {error, term()}.
check_peerbook(TID, MAddr) ->
    {ok, {RAddress, SAddress}} = libp2p_relay:p2p_circuit(MAddr),
    Swarm = libp2p_swarm:swarm(TID),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    RelayAddress = libp2p_crypto:p2p_to_pubkey_bin(RAddress),
    ServerAddress = libp2p_crypto:p2p_to_pubkey_bin(SAddress),
    case libp2p_peerbook:get(Peerbook, RelayAddress) of
        {ok, Peer} ->
            lists:member(ServerAddress, libp2p_peer:connected_peers(Peer));
        Error ->
            Error
    end.

-spec connect_rcv(pid(), string(), string(), pid()) -> {ok, pid()} | {error, term()}.
connect_rcv(Swarm, MAddr, SAddress, SessionPid) ->
    receive
        {sessions, [SessionPid2|_]=Sessions} ->
            lager:info("using sessions: ~p instead of ~p", [Sessions, SessionPid]),
            libp2p_relay:unreg_addr_sessions(SAddress),
            {ok, SessionPid2};
        {error, "server_down"}=Error ->
            libp2p_relay:unreg_addr_sessions(SAddress),
            MarkedPeerAddr = libp2p_crypto:p2p_to_pubkey_bin(SAddress),
            PeerBook = libp2p_swarm:peerbook(Swarm),
            ok = libp2p_peerbook:blacklist_listen_addr(PeerBook, MarkedPeerAddr, MAddr),
            Error;
        {error, _Reason}=Error ->
            libp2p_relay:unreg_addr_sessions(SAddress),
            lager:error("no relay sessions ~p", [_Reason]),
            Error;
        _Any ->
            lager:debug("got unknown message ~p", [_Any]),
            connect_rcv(Swarm, MAddr, SAddress, SessionPid)
    after 15000 ->
        libp2p_relay:unreg_addr_sessions(SAddress),
        {error, timeout_relay_session}
    end.