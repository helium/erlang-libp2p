-module(libp2p_transport_tcp).

-behavior(gen_server).


-define(DEFAULT_CONNECT_TIMEOUT, 5000).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% libp2p_transport
-export([start_listener/2,
         connect/3,
         dial/4,
         match_addr/2,
         sort_addrs/1,
         priority/0]).

%% gen_server
-export([start_link/1,
         init/1,
         handle_call/3,
         handle_info/2,
         handle_cast/2,
         terminate/2]).

%% for tcp sockets
-export([to_multiaddr/1, from_multiaddr/1,
         get_non_local_addrs/0,
         tcp_addr/1,
         ip_addr_type/1,
         rfc1918/1,
         reuseport_raw_option/0]).

-record(state,
        {
         tid :: ets:tab(),
         stun_txns=#{} :: #{libp2p_stream_stungun:txn_id() => string()},
         observed_addrs=sets:new() :: sets:set(string()),
         negotiated_nat=false :: boolean()
        }).


-spec start_listener(pid(), string()) -> {ok, [string()], pid()} | {error, term()}.
start_listener(Pid, Addr) ->
    gen_server:call(Pid, {start_listener, Addr}).

-spec connect(Transport::pid(), MAddr::string(), Opts::map()) -> {ok, pid()} | {error, term()}.
connect(_Pid, MAddr, Opts=#{tid := TID}) ->
    ListenAddrs = libp2p_config:listen_addrs(TID),
    SessionSup = libp2p_swarm_session_sup:sup(TID),
    ChildOpts = Opts#{ addr => MAddr,
                       from_port => find_matching_listen_port(MAddr, ListenAddrs),
                       handlers => libp2p_config:lookup_connection_handlers(TID)},
    ChildSpec = #{ id => make_ref(),
                   start => {libp2p_stream_tcp, start_link, [client, ChildOpts]},
                   restart => temporary,
                   shutdown => 5000,
                   type => worker },
    SessionSup = libp2p_swarm_session_sup:sup(TID),
    supervisor:start_child(SessionSup, ChildSpec).

-spec dial(Transpor::pid(), MAddr::string(), Opts::map(), Handler::libp2p_stream_multistream:handler())
          -> {ok, Muxee::pid()} | {error, term()}.
dial(Pid, MAddr, Opts0, Handler) ->
    Opts = Opts0#{
                  stream_handler => {Pid, {MAddr, Handler}}
                 },
    connect(Pid, MAddr, Opts).


-spec match_addr(string(), ets:tab()) -> {ok, string()} | false.
match_addr(Addr, _TID) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(Addr)).

-spec sort_addrs([string()]) -> [string()].
sort_addrs(Addrs) ->
    AddressesForDefaultRoutes = [ A || {ok, A} <- [catch inet_parse:address(inet_ext:get_internal_address(Addr)) || {_Interface, Addr} <- inet_ext:gateways(), Addr /= [], Addr /= undefined]],
    sort_addrs(Addrs, AddressesForDefaultRoutes).

-spec sort_addrs([string()], [inet:ip_address()]) -> [string()].
sort_addrs(Addrs, AddressesForDefaultRoutes) ->
    AddrIPs = lists:filtermap(fun(A) ->
        case tcp_addr(A) of
            {error, _} -> false;
            {IP, _} -> {true, {A, IP}}
        end
    end, Addrs),
    SortedAddrIps = lists:sort(fun({_, AIP}, {_, BIP}) ->
        AIP_1918 = not (false == rfc1918(AIP)),
        BIP_1918 = not (false == rfc1918(BIP)),
        case AIP_1918 == BIP_1918 of
            %% Same kind of IP address to a straight compare
            true ->
                %% check if one of them is a the default route network
                case {lists:member(AIP, AddressesForDefaultRoutes),
                     lists:member(BIP, AddressesForDefaultRoutes)} of
                    {X, X} -> %% they're the same
                        AIP =< BIP;
                    {X, _} ->
                        %% different, so return if A is a default route address or not
                        X
                end;
            %% Different, A <= B if B is a 1918 addr but A is not
            false -> BIP_1918 andalso not AIP_1918
        end
    end, AddrIPs),
    {SortedAddrs, _} = lists:unzip(SortedAddrIps),
    SortedAddrs.

-spec priority() -> integer().
priority() -> 2.

match_protocols([A={_, _}, B={"tcp", _} | _]) ->
    {ok, multiaddr:to_string([A, B])};
match_protocols(_) ->
    false.


-spec tcp_addr(string() | multiaddr:multiaddr()) -> {inet:ip_address(), non_neg_integer()} | {error, term()}.
tcp_addr(MAddr) ->
    tcp_addr(MAddr, multiaddr:protocols(MAddr)).

%% return RFC1918 mask for IP or false if not in RFC1918 range
rfc1918({10, _, _, _}) ->
    8;
rfc1918({192,168, _, _}) ->
    16;
rfc1918(IP={172, _, _, _}) ->
    %% this one is a /12, not so simple
    case mask_address({172, 16, 0, 0}, 12) == mask_address(IP, 12) of
        true ->
            12;
        false ->
            false
    end;
rfc1918(_) ->
    false.

%% gen_server
%%

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),

    libp2p_swarm:add_stream_handler(TID, {libp2p_stream_stungun:protocol_id(),
                                          {libp2p_stream_stungun, #{}}}), %% self(), TID]}),
    %% libp2p_relay:add_stream_handler(TID),
    %% libp2p_proxy:add_stream_handler(TID),

    {ok, #state{tid=TID}}.

%% libp2p_transport
%%
handle_call({start_listener, Addr}, _From, State=#state{tid=TID}) ->
    Response =
        case listen_on(Addr, TID) of
            {ok, ListenIPPorts, Pid} ->
                ListenAddrs = [to_multiaddr(L) || L <- ListenIPPorts],
                %% libp2p_nat:maybe_spawn_discovery(self(), ListenAddrs, TID),
                libp2p_config:insert_listener(TID, ListenAddrs, Pid),
                {ok, ListenAddrs, Pid};
            {error, Error} -> {error, Error}
        end,
    {reply, Response, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

%% Connect
%%
handle_info({stream_muxer, {_MAddr, DialHandler}, MuxerPid}, State=#state{}) ->
    libp2p_stream_muxer:dial(MuxerPid, #{handlers => [DialHandler]}),
    {noreply, State};


%%  Discover/Stun
%%
handle_info({handle_identify, Session, {error, Error}}, State=#state{}) ->
    {_LocalAddr, PeerAddr} = libp2p_session:addr_info(Session),
    lager:notice("session identification failed for ~p: ~p", [PeerAddr, Error]),
    {noreply, State};
handle_info({handle_identify, Session, {ok, Identify}}, State=#state{tid=TID}) ->
    {LocalAddr, _PeerAddr} = libp2p_session:addr_info(Session),
    RemoteP2PAddr = libp2p_crypto:pubkey_bin_to_p2p(libp2p_identify:pubkey_bin(Identify)),
    {ok, MyPeer} = libp2p_peerbook:get(libp2p_swarm:peerbook(TID), libp2p_swarm:pubkey_bin(TID)),
    ListenAddrs = libp2p_peer:listen_addrs(MyPeer),
    case lists:member(LocalAddr, ListenAddrs) of
        true ->
            ObservedAddr = libp2p_identify:observed_addr(Identify),
            {noreply, record_observed_addr(RemoteP2PAddr, ObservedAddr, State)};
        false ->
            %% check if our listen addrs have changed
            %% find all the listen addrs owned by this transport
            MyListenAddrs = [ LA || LA <- ListenAddrs, match_addr(LA, TID) /= false ],
            NewListenAddrsWithPid = case MyListenAddrs of
                                        [] ->
                                            %% engage desperation mode, we had no listen addresses before, but maybe we have some now because someone plugged in a cable or configured wifi
                                            [ {tcp_listen_addrs(S), Pid} || {Pid, Addr, S} <- libp2p_config:listen_sockets(TID), match_addr(Addr, TID) /= false ];
                                        _ ->
                                            %% find the distinct list of listen addrs for each listen socket
                                            lists:foldl(fun(LA, Acc) ->
                                                                case libp2p_config:lookup_listener(TID, LA) of
                                                                    {ok, Pid} ->
                                                                        case lists:keymember(Pid, 2, Acc) of
                                                                            true ->
                                                                                Acc;
                                                                            false ->
                                                                                case libp2p_config:lookup_listen_socket(TID, Pid) of
                                                                                    {ok, {_ListenAddr, S}} ->
                                                                                        [{tcp_listen_addrs(S), Pid} | Acc];
                                                                                    false ->
                                                                                        Acc
                                                                                end
                                                                        end;
                                                                    false ->
                                                                        Acc
                                                                end
                                                        end, [], MyListenAddrs)
                                    end,
            %% don't use lists flatten here as it flattens too much
            NewListenAddrs = lists:foldl(fun(E, A) -> E ++ A end, [], (element(1, lists:unzip(NewListenAddrsWithPid)))),
            case lists:member(LocalAddr, NewListenAddrs) orelse (ListenAddrs == [] andalso NewListenAddrs /= []) of
                true ->
                    %% they have changed, or we never had any; add any new ones and remove any old ones
                    ObservedAddr = libp2p_identify:observed_addr(Identify),
                    %% find listen addresses for this transport
                    MyListenAddrs = [ LA || LA <- ListenAddrs, match_addr(LA, TID) /= false ],
                    RemovedListenAddrs = MyListenAddrs -- NewListenAddrs,
                    lager:debug("Listen addresses changed: ~p -> ~p", [MyListenAddrs, NewListenAddrs]),
                    [ libp2p_config:remove_listener(TID, A) || A <- RemovedListenAddrs ],
                    %% we can simply re-add all of the addresses again, overrides are fine
                    [ libp2p_config:insert_listener(TID, LAs, P) || {LAs, P} <- NewListenAddrsWithPid],
                    PB = libp2p_swarm:peerbook(TID),
                    libp2p_peerbook:changed_listener(PB),
                    {noreply, record_observed_addr(RemoteP2PAddr, ObservedAddr, State)};
                false ->
                    lager:debug("identify response with local address ~p that is not a listen addr socket ~p, ignoring",
                                [LocalAddr, NewListenAddrs]),
                    %% this is likely a discovery session we dialed with unique_port
                    %% we can't trust this for the purposes of the observed address
                    {noreply, State}
            end
    end;
handle_info(stungun_retry, State=#state{observed_addrs=Addrs, tid=TID, stun_txns=StunTxns}) ->
    case most_observed_addr(Addrs) of
        {ok, ObservedAddr} ->
            {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(),
            %% choose a random connected peer to do stungun with
            {ok, MyPeer} = libp2p_peerbook:get(libp2p_swarm:peerbook(TID), libp2p_swarm:pubkey_bin(TID)),
            MyConnectedPeers = [libp2p_crypto:pubkey_bin_to_p2p(P) || P <- libp2p_peer:connected_peers(MyPeer)],
            PeerAddr = lists:nth(rand:uniform(length(MyConnectedPeers)), MyConnectedPeers),
            lager:debug("retrying stungun with peer ~p", [PeerAddr]),
            case libp2p_stream_stungun:dial(TID, PeerAddr, PeerPath, TxnID, self()) of
                {ok, StunPid} ->
                    %% TODO: Remove this once dial stops using start_link
                    unlink(StunPid),
                    erlang:send_after(60000, self(), {stungun_timeout, TxnID}),
                    {noreply, State#state{stun_txns=add_stun_txn(TxnID, ObservedAddr, StunTxns)}};
                _ ->
                    {noreply, State}
            end;
        error ->
            %% we need at least 2 peers to agree on the observed address
            {noreply, State}
    end;
handle_info({stungun_nat, TxnID, NatType}, State=#state{tid=TID, stun_txns=StunTxns}) ->
    case maps:is_key(TxnID, StunTxns) of
        true ->
            lager:debug("stungun detected NAT type ~p", [NatType]),
            case NatType of
                none ->
                    %% don't need to start relay here, stop any we already have
                    libp2p_relay_server:stop(libp2p_swarm:swarm(TID)),
                    %% if we didn't have an external address originally, set the NAT type to 'static'
                    case State#state.negotiated_nat of
                        true ->
                            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), static);
                        false ->
                            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), none)
                    end;
                unknown ->
                    %% stungun failed to resolve, so we have to retry later
                    erlang:send_after(30000, self(), stungun_retry);
                _ ->
                    %% we have either port restricted cone NAT or symmetric NAT
                    %% and we need to start a relay
                    libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), NatType),
                    libp2p_relay:init(libp2p_swarm:swarm(TID))
            end,
            {noreply, State};
        false ->
            {noreply, State}
    end;
handle_info({stungun_timeout, TxnID}, State=#state{stun_txns=StunTxns}) ->
    case maps:is_key(TxnID, StunTxns) of
        true ->
            lager:debug("stungun timed out"),
            %% note we only remove the txnid here, because we can get multiple messages
            %% for this txnid
            {noreply, State#state{stun_txns=remove_stun_txn(TxnID, StunTxns)}};
        false ->
            {noreply, State}
    end;
handle_info({stungun_reply, TxnID, LocalAddr}, State=#state{tid=TID, stun_txns=StunTxns}) ->
    case maps:find(TxnID, StunTxns) of
        error -> {noreply, State};
        {ok, ObservedAddr} ->
            lager:debug("Got dial back confirmation of observed address ~p", [ObservedAddr]),
            case libp2p_config:lookup_listener(TID, LocalAddr) of
                {ok, ListenerPid} ->
                    libp2p_config:insert_listener(TID, [ObservedAddr], ListenerPid);
                false ->
                    lager:notice("unable to determine listener pid for ~p", [LocalAddr])
            end,
            {noreply, State}
    end;
handle_info({nat_discovered, InternalAddr, ExternalAddr}, State=#state{tid=TID}) ->
    case libp2p_config:lookup_listener(TID, InternalAddr) of
        {ok, ListenPid} ->
            lager:debug("added port mapping from ~s to ~s", [InternalAddr, ExternalAddr]),
            libp2p_config:insert_listener(TID, [ExternalAddr], ListenPid),
            %% TODO if the nat type has resolved to 'none' here we should change it to static
            {noreply, State#state{negotiated_nat=true}};
        _ ->
            {noreply, State}
    end;
handle_info(Msg, State) ->
    lager:warning("Unhandled message ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{}) ->
    ok.

%% Internal: Listen/Connect
%%

-spec listen_on(string(), ets:tab()) -> {ok, [string()], pid()} | {error, term()}.
listen_on(Addr, TID) ->
    Sup = libp2p_swarm_listener_sup:sup(TID),
    case tcp_addr(Addr) of
        {error, Error} ->
            {error, Error};
        {IP, Port} ->
            Opts = #{
                     cache_dir => libp2p_config:swarm_dir(TID, []),
                     handler_fn => fun() ->
                                           libp2p_config:lookup_connection_handlers(TID)
                                   end
                    },
            ListenSpec = #{
                           id => {?MODULE, Addr},
                           start => {libp2p_transport_tcp_listen_sup, start_link, [IP, Port, Opts]},
                           type => supervisor
                          },
            case supervisor:start_child(Sup, ListenSpec) of
                {ok, Pid} ->
                    ListenAddrs = libp2p_transport_tcp_listen_sup:listen_addrs(Pid),
                    {ok, ListenAddrs, Pid};
                {error, Error} ->
                    {error, Error}
            end
    end.


find_matching_listen_port(_Addr, []) ->
    0;
find_matching_listen_port(Addr, [H|ListenAddrs]) ->
    ListenAddr = multiaddr:new(H),
    ConnectProtocols = [ element(1, T) || T <- multiaddr:protocols(Addr)],
    ListenProtocols = [ element(1, T) || T <- multiaddr:protocols(ListenAddr)],
    case ConnectProtocols == ListenProtocols of
        true ->
            {_, Port} = tcp_addr(ListenAddr),
            Port;
        false ->
            find_matching_listen_port(Addr, ListenAddrs)
    end.

reuseport_raw_option() ->
    %% TODO provide a more complete mapping of SOL_SOCKET and SO_REUSEPORT
    {Protocol, Option} = case os:type() of
                             {unix, linux} ->
                                 {1, 15};
                             {unix, freebsd} ->
                                 {16#ffff, 16#200};
                             {unix, darwin} ->
                                 {16#ffff, 16#200}
                         end,
    {raw, Protocol, Option, <<1:32/native>>}.

tcp_listen_addrs(Socket) ->
    {ok, SockAddr={IP, Port}} = inet:sockname(Socket),
    case lists:all(fun(D) -> D == 0 end, tuple_to_list(IP)) of
        false ->
            [to_multiaddr(libp2p_nat:maybe_apply_nat_map(SockAddr))];
        true ->
            % all 0 address, collect all non loopback interface addresses
            Addresses = get_non_local_addrs(),
            [to_multiaddr(libp2p_nat:maybe_apply_nat_map({Addr, Port}))
                || Addr <- Addresses, size(Addr) == size(IP)]
    end.


to_multiaddr({IP, Port}) when is_tuple(IP) andalso is_integer(Port) ->
    Prefix  = case size(IP) of
                  4 -> "/ip4";
                  8 -> "/ip6"
              end,
    lists:flatten(io_lib:format("~s/~s/tcp/~b", [Prefix, inet:ntoa(IP), Port ])).

from_multiaddr(Addr) ->
    case (catch multiaddr:protocols(Addr)) of
        [{AddrType, Address}, {"tcp", PortStr}] ->
            Port = list_to_integer(PortStr),
            case AddrType of
                "ip4" ->
                    {ok, IP} = inet:parse_ipv4_address(Address),
                    {ok, {IP, Port}};
                "ip6" ->
                    {ok, IP} = inet:parse_ipv6_address(Address),
                    {ok, {IP, Port}}
            end;
        _ ->
            {error, {invalid_address, Addr}}
    end.

get_non_local_addrs() ->
    {ok, IFAddrs} = inet:getifaddrs(),
    [
        Addr || {_, Opts} <- IFAddrs
        ,{addr, Addr} <- Opts
        ,{flags, Flags} <- Opts
        %% filter out loopbacks
        ,not lists:member(loopback, Flags)
        %% filter out ipv6 link-local addresses
        ,not (filter_ipv6(Addr))
        %% filter out RFC3927 ipv4 link-local addresses
        ,not (filter_ipv4(Addr))
    ].

filter_ipv4(Addr) ->
    erlang:size(Addr) == 4
        andalso erlang:element(1, Addr) == 169
        andalso erlang:element(2, Addr) == 254.

filter_ipv6(Addr) ->
    erlang:size(Addr) == 8
        andalso erlang:element(1, Addr) == 16#fe80.


ip_addr_type(IP) ->
    case size(IP) of
        4 -> inet;
        8 -> inet6
    end.

tcp_addr(Addr, [{AddrType, Address}, {"tcp", PortStr}]) ->
    Port = list_to_integer(PortStr),
    case AddrType of
        "ip4" ->
            {ok, IP} = inet:parse_ipv4_address(Address),
            {IP, Port};
        "ip6" ->
            {ok, IP} = inet:parse_ipv6_address(Address),
            {IP, Port};
        _ -> {error, {unsupported_address, Addr}}
    end;
tcp_addr(Addr, _Protocols) ->
    {error, {unsupported_address, Addr}}.



%% Internal: Discover/Stun
%%

add_stun_txn(TxnID, ObservedAddr, Txns) ->
    maps:put(TxnID, ObservedAddr, Txns).

remove_stun_txn(TxnID, Txns) ->
    maps:remove(TxnID, Txns).

add_observed_addr(PeerAddr, ObservedAddr, Addrs) ->
    sets:add_element({PeerAddr, ObservedAddr}, Addrs).

is_observed_addr(PeerAddr, ObservedAddr, Addrs) ->
    sets:is_element({PeerAddr, ObservedAddr}, Addrs).

is_observed_addr(ObservedAddr, Addrs) ->
    sets:fold(fun({_, O}, false) -> O == ObservedAddr;
                 (_, true) -> true
              end,
              false, Addrs).

most_observed_addr(Addrs) ->
    lager:debug("observed addresses ~p", [Addrs]),
    {_, ObservedAddrs} = lists:unzip(sets:to_list(Addrs)),
    Counts = dict:to_list(lists:foldl(fun(A, D) ->
                                              dict:update_counter(A, 1, D)
                                      end, dict:new(), ObservedAddrs)),
    lager:debug("most observed addresses ~p", [Counts]),
    [{MostObservedAddr, Count} |_] = lists:reverse(lists:keysort(1, Counts)),
    case Count >= 2 of
        true ->
            {ok, MostObservedAddr};
        false ->
            error
    end.


-spec record_observed_addr(string(), string(), #state{}) -> #state{}.
record_observed_addr(PeerAddr, ObservedAddr, State=#state{tid=TID, observed_addrs=ObservedAddrs, stun_txns=StunTxns}) ->
    lager:notice("recording observed address ~p ~p", [PeerAddr, ObservedAddr]),
    case is_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs) of
        true ->
            % this peer already told us about this observed address
            State;
        false ->
            % check if another peer has seen this address
            case is_observed_addr(ObservedAddr, ObservedAddrs) of
                true ->
                    %% ok, we have independant confirmation of an observed address
                    lager:debug("received confirmation of observed address ~s", [ObservedAddr]),
                    {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(),
                    %% Record the TxnID , then convince a peer to dial us back with that TxnID
                    %% then that handler needs to forward the response back here, so we can add the external address
                    lager:debug("attempting to discover network status using stungun with ~p", [PeerAddr]),
                    case libp2p_stream_stungun:dial(TID, PeerAddr, PeerPath, TxnID, self()) of
                        {ok, StunPid} ->
                            %% TODO: Remove this once dial stops using start_link
                            unlink(StunPid),
                            erlang:send_after(60000, self(), {stungun_timeout, TxnID}),
                            State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs),
                                        stun_txns=add_stun_txn(TxnID, ObservedAddr, StunTxns)};
                        _ ->
                            State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs)}
                    end;
                false ->
                    lager:debug("peer ~p informed us of our observed address ~p", [PeerAddr, ObservedAddr]),
                    State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs)}
            end
    end.

%mask_address(_, _) ->
    %% presumably ipv6, don't have a function for that one yet
    %undefined.

%% @doc Get the subnet mask as an integer, stolen from an old post on
%%      erlang-questions.
-spec mask_address(inet:ip_address(), pos_integer()) -> integer().
mask_address(Addr={_, _, _, _}, Maskbits) ->
    B = list_to_binary(tuple_to_list(Addr)),
    <<Subnet:Maskbits, _Host/bitstring>> = B,
    Subnet.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

rfc1918_test() ->
    ?assertEqual(8, rfc1918({10, 0, 0, 0})),
    ?assertEqual(8, rfc1918({10, 20, 0, 0})),
    ?assertEqual(8, rfc1918({10, 1, 1, 1})),
    ?assertEqual(16, rfc1918({192, 168, 10, 1})),
    ?assertEqual(16, rfc1918({192, 168, 20, 1})),
    ?assertEqual(16, rfc1918({192, 168, 30, 1})),
    ?assertEqual(12, rfc1918({172, 16, 1, 0})),
    ?assertEqual(12, rfc1918({172, 16, 10, 0})),
    ?assertEqual(12, rfc1918({172, 16, 100, 0})),
    ?assertEqual(false, rfc1918({11, 0, 0, 0})),
    ?assertEqual(false, rfc1918({192, 169, 10, 1})),
    ?assertEqual(false, rfc1918({172, 254, 100, 0})).

sort_addr_test() ->
    Addrs = [
        "/ip4/10.0.0.0/tcp/22"
        ,"/ip4/207.148.0.20/tcp/100"
        ,"/ip4/10.0.0.1/tcp/19"
        ,"/ip4/192.168.1.16/tcp/18"
        ,"/ip4/207.148.0.21/tcp/101"
    ],
    ?assertEqual(
        ["/ip4/207.148.0.20/tcp/100"
         ,"/ip4/207.148.0.21/tcp/101"
         ,"/ip4/10.0.0.0/tcp/22"
         ,"/ip4/10.0.0.1/tcp/19"
         ,"/ip4/192.168.1.16/tcp/18"]
        ,sort_addrs(Addrs, [])
    ),
    %% check that 'default route' addresses sort first, within their class
    ?assertEqual(
        ["/ip4/207.148.0.20/tcp/100"
         ,"/ip4/207.148.0.21/tcp/101"
         ,"/ip4/192.168.1.16/tcp/18"
         ,"/ip4/10.0.0.0/tcp/22"
         ,"/ip4/10.0.0.1/tcp/19"]
        ,sort_addrs(Addrs, [{192, 168, 1, 16}])
    ),
    ok.

-endif.
