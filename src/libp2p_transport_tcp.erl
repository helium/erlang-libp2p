-module(libp2p_transport_tcp).

-behaviour(libp2p_connection).
-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type listen_opt() :: {backlog, non_neg_integer()}
                    | {buffer, non_neg_integer()}
                    | {delay_send, boolean()}
                    | {dontroute, boolean()}
                    | {exit_on_close, boolean()}
                    | {fd, non_neg_integer()}
                    | {high_msgq_watermark, non_neg_integer()}
                    | {high_watermark, non_neg_integer()}
                    | {keepalive, boolean()}
                    | {linger, {boolean(), non_neg_integer()}}
                    | {low_msgq_watermark, non_neg_integer()}
                    | {low_watermark, non_neg_integer()}
                    | {nodelay, boolean()}
                    | {port, inet:port_number()}
                    | {priority, integer()}
                    | {raw, non_neg_integer(), non_neg_integer(), binary()}
                    | {recbuf, non_neg_integer()}
                    | {send_timeout, timeout()}
                    | {send_timeout_close, boolean()}
                    | {sndbuf, non_neg_integer()}
                    | {tos, integer()}.

-type opt() :: {listen, [listen_opt()]}.

-export_type([opt/0, listen_opt/0]).

%% libp2p_transport
-export([start_listener/2, new_connection/1, new_connection/2,
         connect/5, match_addr/2, sort_addrs/1, priority/0]).

%% gen_server
-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

%% libp2p_connection
-export([send/3, recv/3, acknowledge/2, addr_info/1,
         close/1, close_state/1, controlling_process/2,
         session/1, fdset/1, socket/1, fdclr/1
        ]).

%% for tcp sockets
-export([to_multiaddr/1, common_options/0, tcp_addr/1, rfc1918/1]).

-record(tcp_state,
        {
         addr_info :: {string(), string()},
         socket :: gen_tcp:socket(),
         session=undefined :: pid() | undefined,
         transport :: atom()
        }).

-type tcp_state() :: #tcp_state{}.

-record(state,
        {
         tid :: ets:tab(),
         stun_txns=#{} :: #{libp2p_stream_stungun:txn_id() => string()},
         observed_addrs=sets:new() :: sets:set(string()),
         negotiated_nat=false :: boolean()
        }).


%% libp2p_transport
%%

-spec new_connection(inet:socket()) -> libp2p_connection:connection().
new_connection(Socket) ->
    {ok, RemoteAddr} = inet:peername(Socket),
    new_connection(Socket, to_multiaddr(RemoteAddr)).

-spec new_connection(inet:socket(), string()) -> libp2p_connection:connection().
new_connection(Socket, PeerName) when is_list(PeerName) ->
    {ok, LocalAddr} = inet:sockname(Socket),
    libp2p_connection:new(?MODULE, #tcp_state{addr_info={to_multiaddr(LocalAddr), PeerName},
                                              socket=Socket,
                                              transport=ranch_tcp}).

-spec start_listener(pid(), string()) -> {ok, [string()], pid()} | {error, term()}.
start_listener(Pid, Addr) ->
    gen_server:call(Pid, {start_listener, Addr}).

-spec connect(pid(), string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab())
             -> {ok, pid()} | {error, term()}.
connect(Pid, MAddr, Options, Timeout, TID) ->
    connect_to(MAddr, Options, Timeout, TID, Pid).

-spec match_addr(string(), ets:tab()) -> {ok, string()} | false.
match_addr(Addr, _TID) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(Addr)).

-spec sort_addrs([string()]) -> [string()].
sort_addrs(Addrs) ->
    AddressesForDefaultRoutes = [ A || {ok, A} <- [inet_parse:address(inet_ext:get_internal_address(Addr)) || {_Interface, Addr} <- inet_ext:gateways(), Addr /= [], Addr /= undefined]],
    sort_addrs(Addrs, AddressesForDefaultRoutes).

-spec sort_addrs([string()], [inet:ip_address()]) -> [string()].
sort_addrs(Addrs, AddressesForDefaultRoutes) ->
    AddrIPs = lists:filtermap(fun(A) ->
        case tcp_addr(A) of
            {error, _} -> false;
            {IP, _, _, _} -> {true, {A, IP}}
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


%% libp2p_connection
%%
-spec send(tcp_state(), iodata(), non_neg_integer()) -> ok | {error, term()}.
send(#tcp_state{socket=Socket, transport=Transport}, Data, _Timeout) ->
    Transport:send(Socket, Data).

-spec recv(tcp_state(), non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, term()}.
recv(#tcp_state{socket=Socket, transport=Transport}, Length, Timeout) ->
    Transport:recv(Socket, Length, Timeout).

-spec close(tcp_state()) -> ok.
close(#tcp_state{socket=Socket, transport=Transport}) ->
    Transport:close(Socket).

-spec close_state(tcp_state()) -> open | closed.
close_state(#tcp_state{socket=Socket}) ->
    case inet:peername(Socket) of
        {ok, _} -> open;
        {error, _} -> closed
    end.

-spec acknowledge(tcp_state(), reference()) -> ok.
acknowledge(#tcp_state{}, Ref) ->
    ranch:accept_ack(Ref).

fdset_loop(Socket, Parent, Count) ->
    %% this may screw up TLS sockets...
    Event = case gen_tcp:recv(Socket, 1, 1000) of
                {ok, P} ->
                    ok = gen_tcp:unrecv(Socket, P),
                    true;
                {error, timeout} ->
                    %% timeouts are not an event, they're just a way to handle fdclrs
                    false;
                {error, _R} ->
                    true
            end,
    receive {Ref, clear} ->
                Parent ! {Ref, ok};
            {Ref, fdset} ->
                Parent ! {Ref, {error, already_fdset}}
    after 0 ->
              case Event of
                  false ->
                      %% resume waiting
                      fdset_loop(Socket, Parent, Count);
                  true ->
                      Parent ! {inert_read, Count, Socket},
                      receive {Ref, fdset} ->
                                  Parent ! {Ref, ok},
                                  fdset_loop(Socket, Parent, Count + 1);
                              {Ref, clear} ->
                                  Parent ! {Ref, ok}
                      end
              end
    end.

-spec fdset(tcp_state()) -> ok | {error, term()}.
fdset(#tcp_state{socket=Socket}=State) ->
    %% XXX This is a temporary fix to remove inert while we rework connections to be
    %% event driven and not use recv at all
    Parent = self(),
    case erlang:get(fdset_pid) of
        undefined ->
            Pid = spawn(fun() ->
                                fdset_loop(Socket, Parent, 1)
                        end),
            erlang:put(fdset_pid, Pid),
            ok;
        Pid ->
            case is_process_alive(Pid) of
                true ->
                    Ref = erlang:monitor(process, Pid),
                    Pid ! {Ref, fdset},
                    receive {Ref, Return} ->
                                erlang:demonitor(Ref, [flush]),
                                Return;
                            {'DOWN', Ref, process, Pid, Reason} ->
                                {error, Reason}
                    end;
                false ->
                    erlang:put(fdset_pid, undefined),
                    fdset(State)
            end
    end.

-spec socket(tcp_state()) -> gen_tcp:socket().
socket(#tcp_state{socket=Socket}) ->
    Socket.

-spec fdclr(tcp_state()) -> ok.
fdclr(#tcp_state{socket=Socket}) ->
    case erlang:get(fdset_pid) of
        undefined ->
            ok;
        Pid ->
            case is_process_alive(Pid) of
                true ->
                    Ref = erlang:monitor(process, Pid),
                    Pid ! {Ref, clear},
                    receive {Ref, Return} ->
                                erlang:demonitor(Ref, [flush]),
                                %% consume any messages of this form in the mailbox
                                receive
                                    {inert_read, _N, Socket} ->
                                        ok
                                after 0 ->
                                          ok
                                end,
                                erlang:put(fdset_pid, undefined),
                                Return;
                            {'DOWN', Ref, process, Pid, Reason} ->
                                erlang:put(fdset_pid, undefined),
                                {error, Reason}
                    end;
                false ->
                    erlang:put(fdset_pid, undefined),
                    ok
            end
    end.

-spec addr_info(tcp_state()) -> {string(), string()}.
addr_info(#tcp_state{addr_info=AddrInfo}) ->
    AddrInfo.

-spec session(tcp_state()) -> {ok, pid()} | {error, term()}.
session(#tcp_state{session=undefined}) ->
    {error, no_session};
session(#tcp_state{session=Session}) ->
    {ok, Session}.

-spec controlling_process(tcp_state(), pid())
                         ->  {ok, tcp_state()} | {error, closed | not_owner | atom()}.
controlling_process(State=#tcp_state{socket=Socket}, Pid) ->
    case gen_tcp:controlling_process(Socket, Pid) of
        ok -> {ok, State#tcp_state{session=Pid}};
        Other -> Other
    end.

-spec common_options() -> [term()].
common_options() ->
    [binary, {active, false}, {packet, raw}].

-spec tcp_addr(string() | multiaddr:multiaddr())
              -> {inet:ip_address(), non_neg_integer(), inet | inet6, [any()]} | {error, term()}.
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

    libp2p_swarm:add_stream_handler(TID, "stungun/1.0.0",
                                    {libp2p_framed_stream, server, [libp2p_stream_stungun, self(), TID]}),
    libp2p_relay:add_stream_handler(TID),
    libp2p_proxy:add_stream_handler(TID),
    {ok, #state{tid=TID}}.

%% libp2p_transport
%%
handle_call({start_listener, Addr}, _From, State=#state{tid=TID}) ->
    Response =
        case listen_on(Addr, TID) of
            {ok, ListenAddrs, Pid} ->
                libp2p_nat:maybe_spawn_discovery(self(), ListenAddrs, TID),
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

%%  Discover/Stun
%%
handle_info({handle_identify, Session, {error, Error}}, State=#state{}) ->
    {_LocalAddr, PeerAddr} = libp2p_session:addr_info(Session),
    lager:notice("session identification failed for ~p: ~p", [PeerAddr, Error]),
    {noreply, State};
handle_info({handle_identify, Session, {ok, Identify}}, State=#state{tid=TID}) ->
    {LocalAddr, _PeerAddr} = libp2p_session:addr_info(Session),
    RemoteP2PAddr = libp2p_crypto:address_to_p2p(libp2p_identify:address(Identify)),
    {ok, MyPeer} = libp2p_peerbook:get(libp2p_swarm:peerbook(TID), libp2p_swarm:address(TID)),
    ListenAddrs = libp2p_peer:listen_addrs(MyPeer),
    case lists:member(LocalAddr, ListenAddrs) of
        true ->
            ObservedAddr = libp2p_identify:observed_addr(Identify),
            {noreply, record_observed_addr(RemoteP2PAddr, ObservedAddr, State)};
        false ->
            lager:info("identify response with local address ~p that is not a listen addr socket, ignoring",
                       [LocalAddr]),
            %% this is likely a discovery session we dialed with unique_port
            %% we can't trust this for the purposes of the observed address
            {noreply, State}
    end;
handle_info(stungun_retry, State=#state{observed_addrs=Addrs, tid=TID, stun_txns=StunTxns}) ->
    case most_observed_addr(Addrs) of
        {ok, ObservedAddr} ->
            {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(),
            %% choose a random connected peer to do stungun with
            {ok, MyPeer} = libp2p_peerbook:get(libp2p_swarm:peerbook(TID), libp2p_swarm:address(TID)),
            MyConnectedPeers = [libp2p_crypto:address_to_p2p(P) || P <- libp2p_peer:connected_peers(MyPeer)],
            PeerAddr = lists:nth(rand:uniform(length(MyConnectedPeers)), MyConnectedPeers),
            lager:info("retrying stungun with peer ~p", [PeerAddr]),
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
            lager:info("stungun detected NAT type ~p", [NatType]),
            case NatType of
                none ->
                    %% don't need to start relay here
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
            lager:info("stungun timed out"),
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

-spec listen_options(inet:ip_address(), ets:tab()) -> [term()].
listen_options(IP, TID) ->
    OptionDefaults = [
                      {ip, IP},
                      {backlog, 1024},
                      {nodelay, true},
                      {send_timeout, 30000},
                      {send_timeout_close, true}
                     ],
    % Go get the tcp listen options
    case libp2p_config:get_opt(libp2p_swarm:opts(TID), [?MODULE, listen]) of
        undefined -> OptionDefaults;
        {ok, Values} ->
            sets:to_list(sets:union(sets:from_list(Values),
                                    sets:from_list(OptionDefaults)))
    end.


-spec listen_on(string(), ets:tab()) -> {ok, [string()], pid()} | {error, term()}.
listen_on(Addr, TID) ->
    Sup = libp2p_swarm_listener_sup:sup(TID),
    case tcp_addr(Addr) of
        {IP, Port0, Type, AddrOpts} ->
            ListenOpts0 = listen_options(IP, TID),
            % Non-overidable options, taken from ranch_tcp:listen
            DefaultListenOpts = [{reuseaddr, true}, reuseport()] ++ common_options(),
            % filter out disallowed options and supply default ones
            ListenOpts = ranch:filter_options(ListenOpts0, ranch_tcp:disallowed_listen_options(),
                                              DefaultListenOpts),
            Port1 = reuseport0(TID, Type, IP, Port0),
            % Dialyzer severely dislikes ranch_tcp:listen so we
            % emulate it's behavior here
            case gen_tcp:listen(Port1, [Type | AddrOpts] ++ ListenOpts) of
                {ok, Socket} ->
                    ListenAddrs = tcp_listen_addrs(Socket),

                    Cache = libp2p_swarm:cache(TID),
                    ok = libp2p_cache:insert(Cache, {tcp_listen_addrs, Type}, ListenAddrs),

                    ChildSpec = ranch:child_spec(ListenAddrs,
                                                 ranch_tcp, [{socket, Socket}],
                                                 libp2p_transport_ranch_protocol, {?MODULE, TID}),
                    case supervisor:start_child(Sup, ChildSpec) of
                        {ok, Pid} ->
                            ok = gen_tcp:controlling_process(Socket, Pid),
                            {ok, ListenAddrs, Pid};
                        {error, Reason} ->
                            gen_tcp:close(Socket),
                            {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Error} -> {error, Error}
    end.


-spec connect_to(string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab(), pid())
                -> {ok, pid()} | {error, term()}.
connect_to(Addr, UserOptions, Timeout, TID, TCPPid) ->
    case tcp_addr(Addr) of
        {IP, Port, Type, AddrOpts} ->
            UniqueSession = proplists:get_value(unique_session, UserOptions, false),
            UniquePort = proplists:get_value(unique_port, UserOptions, false),
            ListenAddrs = libp2p_config:listen_addrs(TID),
            Options = connect_options(Type, AddrOpts ++ common_options(), Addr, ListenAddrs,
                                      UniqueSession, UniquePort),
            case ranch_tcp:connect(IP, Port, Options, Timeout) of
                {ok, Socket} ->
                    case libp2p_transport:start_client_session(TID, Addr, new_connection(Socket)) of
                        {ok, SessionPid} ->
                            libp2p_session:identify(SessionPid, TCPPid, SessionPid),
                            {ok, SessionPid};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Reason} -> {error, Reason}
    end.


connect_options(Type, Opts, _, _, UniqueSession, _UniquePort) when UniqueSession == true ->
    [Type | Opts];
connect_options(Type, Opts, _, _, false, _UniquePort) when Type /= inet ->
    [Type | Opts];
connect_options(Type, Opts, _, _, false, UniquePort) when UniquePort == true ->
    [Type, {reuseaddr, true} | Opts];
connect_options(Type, Opts, Addr, ListenAddrs, false, false) ->
    MAddr = multiaddr:new(Addr),
    [Type, {reuseaddr, true}, reuseport(), {port, find_matching_listen_port(MAddr, ListenAddrs)} | Opts].

find_matching_listen_port(_Addr, []) ->
    0;
find_matching_listen_port(Addr, [H|ListenAddrs]) ->
    ListenAddr = multiaddr:new(H),
    ConnectProtocols = [ element(1, T) || T <- multiaddr:protocols(Addr)],
    ListenProtocols = [ element(1, T) || T <- multiaddr:protocols(ListenAddr)],
    case ConnectProtocols == ListenProtocols of
        true ->
            {_, Port, _, _} = tcp_addr(ListenAddr),
            Port;
        false ->
            find_matching_listen_port(Addr, ListenAddrs)
    end.

reuseport() ->
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

reuseport0(TID, Type, {0,0,0,0}, 0) ->
    Cache = libp2p_swarm:cache(TID),
    case libp2p_cache:lookup(Cache, {tcp_listen_addrs, Type}, []) of
        [] -> 0;
        ListenAddrs ->
            TCPAddrs = [tcp_addr(L) || L <- ListenAddrs],
            Ports = [P ||  {_, P, _, _} <- TCPAddrs],
            [P1|_] = Ports,
            Filtered = lists:filter(fun(P) -> P =:= P1 end, Ports),
            case erlang:length(Filtered) =:= erlang:length(TCPAddrs) of
                true -> P1;
                false -> 0
            end
    end;
reuseport0(TID, Type, {0,0,0,0,0,0,0,0}, 0) ->
    Cache = libp2p_swarm:cache(TID),
    case libp2p_cache:lookup(Cache, {tcp_listen_addrs, Type}, []) of
        [] -> 0;
        ListenAddrs ->
            TCPAddrs = [tcp_addr(L) || L <- ListenAddrs],
            Ports = [P ||  {_, P, _, _} <- TCPAddrs],
            [P1|_] = Ports,
            Filtered = lists:filter(fun(P) -> P =:= P1 end, Ports),
            case erlang:length(Filtered) =:= erlang:length(TCPAddrs) of
                true -> P1;
                false -> 0
            end
    end;
reuseport0(TID, Type, IP, 0) ->
    Cache = libp2p_swarm:cache(TID),
    case libp2p_cache:lookup(Cache, {tcp_listen_addrs, Type}, []) of
        [] -> 0;
        ListenAddrs ->
            lists:foldl(
                fun(ListenAddr, 0) ->
                    case tcp_addr(ListenAddr) of
                        {IP, Port, _, _} -> Port;
                        _ -> 0
                    end;
                   (_, Port) ->
                       Port
                end
                ,0
                ,ListenAddrs
            )
    end;
reuseport0(_TID, _Type, _IP, Port) ->
    Port.


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

tcp_addr(Addr, [{AddrType, Address}, {"tcp", PortStr}]) ->
    Port = list_to_integer(PortStr),
    case AddrType of
        "ip4" ->
            {ok, IP} = inet:parse_ipv4_address(Address),
            {IP, Port, inet, []};
        "ip6" ->
            {ok, IP} = inet:parse_ipv6_address(Address),
            {IP, Port, inet6, [{ipv6_v6only, true}]};
        _ -> {error, {unsupported_address, Addr}}
    end;
tcp_addr(Addr, _Protocols) ->
    {error, {unsupported_address, Addr}}.


to_multiaddr({IP, Port}) when is_tuple(IP) andalso is_integer(Port) ->
    Prefix  = case size(IP) of
                  4 -> "/ip4";
                  8 -> "/ip6"
              end,
    lists:flatten(io_lib:format("~s/~s/tcp/~b", [Prefix, inet:ntoa(IP), Port ])).


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
    lager:info("observed addresses ~p", [Addrs]),
    {_, ObservedAddrs} = lists:unzip(sets:to_list(Addrs)),
    Counts = dict:to_list(lists:foldl(fun(A, D) ->
                                              dict:update_counter(A, 1, D)
                                      end, dict:new(), ObservedAddrs)),
    lager:info("most observed addresses ~p", [Counts]),
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
                    lager:info("received confirmation of observed address ~s", [ObservedAddr]),
                    {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(),
                    %% Record the TxnID , then convince a peer to dial us back with that TxnID
                    %% then that handler needs to forward the response back here, so we can add the external address
                    lager:info("attempting to discover network status using stungun with ~p", [PeerAddr]),
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
                    lager:info("peer ~p informed us of our observed address ~p", [PeerAddr, ObservedAddr]),
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
