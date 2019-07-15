-module(libp2p_transport_p2p).

-behavior(libp2p_transport).

% libp2p_transport
-export([
    start_link/1,
    start_listener/2,
    connect/5,
    match_addr/2,
    sort_addrs/1,
    p2p_addr/1
]).


%% libp2p_transport
%%

-spec start_link(ets:tab()) -> ignore.
start_link(_TID) ->
    ignore.

-spec start_listener(pid(), string()) -> {error, unsupported}.
start_listener(_Pid, _Addr) ->
    {error, unsupported}.

-spec connect(pid(), string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab())
             -> {ok, pid()} | {error, term()}.
connect(_Pid, MAddr, Options, Timeout, TID) ->
    connect_to(MAddr, Options, Timeout, TID).

-spec match_addr(string(), ets:tab()) -> {ok, string()} | false.
match_addr(Addr, _TID) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(Addr)).

-spec sort_addrs([string()]) -> [{integer(), string()}].
sort_addrs(Addrs) ->
    [{3, A} || A <- Addrs].

match_protocols([A={"p2p", _}]) ->
    {ok, multiaddr:to_string([A])};
match_protocols(_) ->
    false.

%% Internal: Connect
%%

-spec connect_to(string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab())
                -> {ok, pid()} | {error, term()}.
connect_to(MAddr, UserOptions, Timeout, TID) ->
    case p2p_addr(MAddr) of
        {ok, Addr} ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(TID), Addr) of
                {ok, PeerInfo} ->
                    ListenAddrs = libp2p_peer:cleared_listen_addrs(PeerInfo),
                    case libp2p_transport:find_session(ListenAddrs, UserOptions, TID) of
                        {ok, _, SessionPid} ->
                            libp2p_config:insert_session(TID, MAddr, SessionPid),
                            {ok, SessionPid};
                        {error, not_found} ->
                            SortedListenAddrs = libp2p_transport:sort_addrs(TID, ListenAddrs),
                            case connect_to_listen_addr(SortedListenAddrs, UserOptions, Timeout, TID, []) of
                                {ok, SessionPid}->
                                    libp2p_config:insert_session(TID, MAddr, SessionPid),
                                    {ok, SessionPid};
                                {error, Error} -> {error, Error}
                            end;
                        {error, Error} -> {error, Error}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

-spec connect_to_listen_addr([string()], libp2p_swarm:connect_opts(), pos_integer(), ets:tab(), [{string(), term()}])
                            -> {ok, pid()} | {error, term()}.
connect_to_listen_addr([], _UserOptions, _Timeout, _TID, _Acc) ->
    {error, no_listen_addr};
connect_to_listen_addr([ListenAddr | Tail], UserOptions, Timeout, TID, Acc) ->
    case libp2p_transport:connect_to(ListenAddr, UserOptions, Timeout, TID) of
        {ok, SessionPid} -> {ok, SessionPid};
        {error, Error} ->
            case Tail of
                [] -> {error, lists:reverse([{ListenAddr, Error}|Acc])};
                Remaining -> connect_to_listen_addr(Remaining, UserOptions, Timeout, TID,
                                                    [{ListenAddr, Error}|Acc])
            end
    end.

-spec p2p_addr(string()) -> {ok, libp2p_crypto:pubkey_bin()} | {error, term()}.
p2p_addr(MAddr) ->
    p2p_addr(MAddr, multiaddr:protocols(MAddr)).

p2p_addr(MAddr, [{"p2p", Addr}]) ->
    try
        {ok, libp2p_crypto:b58_to_bin(Addr)}
    catch
        _What:Why ->
            lager:notice("Invalid p2p address ~p: ~p", [MAddr, Why]),
            {error, {invalid_address, MAddr}}
    end;
p2p_addr(MAddr, _Protocols) ->
    {error, {unsupported_address, MAddr}}.
