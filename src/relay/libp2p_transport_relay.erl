-module(libp2p_transport_relay).

-behavior(libp2p_transport).

-export([
    start_link/1,
    start_listener/2,
    match_addr/2,
    sort_addrs/1,
    connect/5
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
               [{"p2p", SwarmAddress}, {"p2p-circuit", "p2p/"++SwarmAddress}] ->
                   lager:info("can't match a relay address for itself"),
                   false;
               _ ->
                   Result
           end;
       false -> false
   end.

-spec sort_addrs([string()]) -> [{integer(), string()}].
sort_addrs(Addrs) ->
    [{2, A} || A <- Addrs].

-spec connect(pid(), string(), libp2p_swarm:connect_opts()
              ,pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect(Pid, MAddr, Options, Timeout, TID) ->
    Swarm = libp2p_swarm:swarm(TID),
    ListenAddresses = libp2p_swarm:listen_addrs(Swarm),
    case proplists:get_value(no_relay, Options, false) of
        true ->
            {error, relay_not_allowed};
        false ->
            case has_public_address(ListenAddresses) of
                true ->
                    connect_to(Pid, MAddr, Options, Timeout, TID);
                false ->
                    libp2p_transport_proxy:connect(Pid, MAddr, [no_relay|Options], Timeout, TID)
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec connect_to(pid(), string(), libp2p_swarm:connect_opts()
                 ,pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect_to(_Pid, MAddr, Options, Timeout, TID) ->
    {ok, {RAddress, SAddress}} = libp2p_relay:p2p_circuit(MAddr),
    lager:info("init relay transport with ~p", [[MAddr, RAddress, SAddress]]),
    true = libp2p_config:insert_relay_sessions(TID, SAddress, self()),
    case RAddress == SAddress of
        true ->
            {error, relay_loop};
        false ->
            case libp2p_transport:connect_to(RAddress, Options, Timeout, TID) of
                {error, _Reason}=Error ->
                    Error;
                {ok, SessionPid} ->
                    Swarm = libp2p_swarm:swarm(TID),
                    {ok, Stream} = libp2p_relay:dial_framed_stream(
                                     Swarm,
                                     RAddress,
                                     [{type, {bridge_cr, MAddr}}]
                                    ),
                    erlang:monitor(process, Stream),
                    connect_rcv(Swarm, MAddr, SAddress, SessionPid, Stream)
            end
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


-spec has_public_address(list()) -> boolean().
has_public_address(Addresses) ->
    lists:any(fun libp2p_transport_tcp:is_public/1, Addresses).

-spec connect_rcv(pid(), string(), string(), pid(), pid()) -> {ok, pid()} | {error, term()}.
connect_rcv(Swarm, MAddr, SAddress, SessionPid, Stream) ->
    receive
        {session, Session} ->
            lager:info("using session: ~p instead of ~p", [Session, SessionPid]),
            true = libp2p_config:remove_relay_sessions(libp2p_swarm:tid(Swarm), SAddress),
            {ok, Session};
        {error, "server_down"}=Error ->
            true = libp2p_config:remove_relay_sessions(libp2p_swarm:tid(Swarm), SAddress),
            MarkedPeerAddr = libp2p_crypto:p2p_to_pubkey_bin(SAddress),
            PeerBook = libp2p_swarm:peerbook(Swarm),
            ok = libp2p_peerbook:blacklist_listen_addr(PeerBook, MarkedPeerAddr, MAddr),
            Error;
        {error, _Reason}=Error ->
            true = libp2p_config:remove_relay_sessions(libp2p_swarm:tid(Swarm), SAddress),
            lager:error("no relay sessions ~p", [_Reason]),
            Error;
        {'DOWN', _Ref, process, Stream, _Reason} ->
            lager:error("stream ~p went down ~p", [Stream, _Reason]),
            {error, stream_down}
    after 15000 ->
        true = libp2p_config:remove_relay_sessions(libp2p_swarm:tid(Swarm), SAddress),
        {error, timeout_relay_session}
    end.
