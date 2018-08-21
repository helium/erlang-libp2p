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
         fdset/1, fdclr/1, common_options/0
        ]).

%% for tcp sockets
-export([to_multiaddr/1]).

-record(tcp_state, {
          addr_info :: {string(), string()},
          socket :: gen_tcp:socket(),
          transport :: atom()
         }).

-type tcp_state() :: #tcp_state{}.

-record(state, {
          tid :: ets:tab(),
          stun_sup ::pid(),
          stun_txns=#{} :: #{},
          observed_addrs=sets:new() :: sets:set()
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
connect(_Pid, MAddr, Options, Timeout, TID) ->
    connect_to(MAddr, Options, Timeout, TID).

-spec match_addr(string(), ets:tab()) -> {ok, string()} | false.
match_addr(Addr, _TID) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(multiaddr:new(Addr))).

-spec sort_addrs([string()]) -> [string()].
sort_addrs(Addrs) ->
    AddressesForDefaultRoutes = [ A || {ok, A} <- [inet_parse:address(inet_ext:get_internal_address(Addr)) || {_Interface, Addr} <- inet_ext:gateways()]],
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

-spec fdset(tcp_state()) -> ok | {error, term()}.
fdset(#tcp_state{socket=Socket}) ->
    case inet:getfd(Socket) of
        {error, Error} -> {error, Error};
        {ok, FD} -> inert:fdset(FD)
    end.

-spec fdclr(tcp_state()) -> ok.
fdclr(#tcp_state{socket=Socket}) ->
    case inet:getfd(Socket) of
        {error, Error} -> {error, Error};
        {ok, FD} -> inert:fdclr(FD)
    end.

-spec addr_info(tcp_state()) -> {string(), string()}.
addr_info(#tcp_state{addr_info=AddrInfo}) ->
    AddrInfo.

-spec controlling_process(tcp_state(), pid()) ->  ok | {error, closed | not_owner | atom()}.
controlling_process(#tcp_state{socket=Socket}, Pid) ->
    gen_tcp:controlling_process(Socket, Pid).

-spec common_options() -> [term()].
common_options() ->
    [binary, {active, false}, {packet, raw}].

%% gen_server
%%

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),

    {ok, StunSup} = supervisor:start_link(libp2p_simple_sup, []),

    libp2p_swarm:add_stream_handler(TID, "stungun/1.0.0",
                                    {libp2p_framed_stream, server, [libp2p_stream_stungun, self(), TID]}),
    libp2p_relay:add_stream_handler(TID),
    libp2p_proxy:add_stream_handler(TID),
    {ok, #state{tid=TID, stun_sup=StunSup}}.

%% libp2p_transport
%%
handle_call({start_listener, Addr}, _From, State=#state{tid=TID}) ->
    Response = case listen_on(Addr, TID) of
                   {ok, ListenAddrs, Pid} ->
                       maybe_spawn_nat_discovery(self(), ListenAddrs, TID),
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
handle_info({identify, _, Session, Identify}, State=#state{}) ->
    {_, PeerAddr} = libp2p_session:addr_info(Session),
    ObservedAddr = libp2p_identify:observed_addr(Identify),
    {noreply, record_observed_addr(PeerAddr, ObservedAddr, State)};
handle_info({stungun_nat, TxnID, NatType}, State=#state{tid=TID, stun_txns=StunTxns}) ->
    libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), NatType),
    {noreply, State#state{stun_txns=remove_stun_txn(TxnID, StunTxns)}};
handle_info({stungun_timeout, TxnID}, State=#state{stun_txns=StunTxns}) ->
    {noreply, State#state{stun_txns=remove_stun_txn(TxnID, StunTxns)}};
handle_info({stungun_reply, TxnID, LocalAddr}, State=#state{tid=TID, stun_txns=StunTxns}) ->
    case take_stun_txn(TxnID, StunTxns) of
        error -> {noreply, State};
        {ObservedAddr, NewStunTxns} ->
            lager:debug("Got dial back confirmation of observed address ~p", [ObservedAddr]),
            case libp2p_config:lookup_listener(TID, LocalAddr) of
                {ok, ListenerPid} ->
                    libp2p_config:insert_listener(TID, [ObservedAddr], ListenerPid);
                false ->
                    lager:notice("unable to determine listener pid for ~p", [LocalAddr])
            end,
            {noreply, State#state{stun_txns=NewStunTxns}}
    end;
handle_info({record_listen_addr, InternalAddr, ExternalAddr}, State=#state{tid=TID}) ->
    case libp2p_config:lookup_listener(TID, InternalAddr) of
        {ok, ListenPid} ->
            lager:debug("added port mapping from ~s to ~s", [InternalAddr, ExternalAddr]),
            libp2p_config:insert_listener(TID, [ExternalAddr], ListenPid),
            {noreply, State};
        _ ->
            {noreply, State}
    end;
handle_info(Msg, _State) ->
    lager:warning("Unhandled message ~p", [Msg]).

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
        {IP, Port, Type, AddrOpts} ->
            ListenOpts0 = listen_options(IP, TID),
            % Non-overidable options, taken from ranch_tcp:listen
            DefaultListenOpts = [{reuseaddr, true}, reuseport()] ++ common_options(),
            % filter out disallowed options and supply default ones
            ListenOpts = ranch:filter_options(ListenOpts0, ranch_tcp:disallowed_listen_options(),
                                              DefaultListenOpts),
            % Dialyzer severely dislikes ranch_tcp:listen so we
            % emulate it's behavior here
            case gen_tcp:listen(Port, [Type | AddrOpts] ++ ListenOpts) of
                {ok, Socket} ->
                    ListenAddrs = tcp_listen_addrs(Socket),
                    %% if we have any non RFC1918 addresses, set the nat type to none
                    Fun = fun(MA) ->
                        [{_, ThisAddr}, _] = multiaddr:protocols(multiaddr:new(MA)),
                        case inet_parse:address(ThisAddr) of
                           {ok, ThisIP} ->
                               rfc1918(ThisIP) == false;
                           _ ->
                               false
                        end
                    end,
                    case lists:any(Fun, ListenAddrs) of
                        true ->
                            lager:notice("setting NAT type to none"),
                            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), none);
                        false ->
                            ok
                    end,
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


-spec connect_to(string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab())
                -> {ok, pid()} | {error, term()}.
connect_to(Addr, UserOptions, Timeout, TID) ->
    case tcp_addr(Addr) of
        {IP, Port, Type, AddrOpts} ->
            UniqueSession = proplists:get_value(unique_session, UserOptions, false),
            UniquePort = proplists:get_value(unique_port, UserOptions, false),
            ListenAddrs = libp2p_config:listen_addrs(TID),
            Options = connect_options(Type, AddrOpts ++ common_options(), Addr, ListenAddrs, UniqueSession, UniquePort),
            case ranch_tcp:connect(IP, Port, Options, Timeout) of
                {ok, Socket} ->
                    libp2p_transport:start_client_session(TID, Addr, new_connection(Socket));
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
            [to_multiaddr(maybe_apply_nat_map(SockAddr))];
        true ->
            % all 0 address, collect all non loopback interface addresses
            {ok, IFAddrs} = inet:getifaddrs(),
            [to_multiaddr(maybe_apply_nat_map({Addr, Port})) ||
             {_, Opts} <- IFAddrs, {addr, Addr} <- Opts, {flags, Flags} <- Opts,
             size(Addr) == size(IP),
             not lists:member(loopback, Flags),
             %% filter out ipv6 link-local addresses
             not (size(Addr) == 8 andalso element(1, Addr) == 16#fe80),
             %% filter out RFC3927 ipv4 link-local addresses
             not (size(Addr) == 4 andalso element(1, Addr) == 169 andalso element(2, Addr) == 254)
            ]
    end.

maybe_apply_nat_map({IP, Port}) ->
    Map = application:get_env(libp2p, nat_map, #{}),
    case maps:get({IP, Port}, Map, maps:get(IP, Map, {IP, Port})) of
        {NewIP, NewPort} ->
            {NewIP, NewPort};
        NewIP ->
            {NewIP, Port}
    end.

-spec tcp_addr(string() | binary())
              -> {inet:ip_address(), non_neg_integer(), inet | inet6, [any()]} | {error, term()}.
tcp_addr(MAddr) when is_binary(MAddr) ->
    tcp_addr(MAddr, multiaddr:protocols(MAddr));
tcp_addr(MAddr) when is_list(MAddr) ->
    tcp_addr(MAddr, multiaddr:protocols(multiaddr:new(MAddr))).

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

take_stun_txn(TxnID, Txns) ->
    maps:take(TxnID, Txns).

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

-spec record_observed_addr(string(), string(), #state{}) -> #state{}.
record_observed_addr(PeerAddr, ObservedAddr, State=#state{tid=TID, observed_addrs=ObservedAddrs, stun_sup=StunSup, stun_txns=StunTxns}) ->
    case libp2p_config:lookup_listener(TID, ObservedAddr) of
        {ok, _} ->
            %% we already know about this observed address
            State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs)};
        false ->
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
                            <<TxnID:96/integer-unsigned-little>> = crypto:strong_rand_bytes(12),
                            %% Record the TxnID , then convince a peer to dial us back with that TxnID
                            %% then that handler needs to forward the response back here, so we can add the external address
                            ChildSpec = #{ id => make_ref(),
                                           start => {libp2p_stream_stungun, start_client, [TxnID, TID, PeerAddr]},
                                           restart => temporary,
                                           shutdown => 5000,
                                           type => worker },
                            {ok, _} = supervisor:start_child(StunSup, ChildSpec),
                            State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs),
                                        stun_txns=add_stun_txn(TxnID, ObservedAddr, StunTxns)};
                        false ->
                            lager:debug("peer ~p informed us of our observed address ~p", [PeerAddr, ObservedAddr]),
                            State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs)}
                    end
            end
    end.


%% Internal: NAT discovery
%%

maybe_spawn_nat_discovery(Handler, MultiAddrs, TID) ->
    case libp2p_config:get_opt(libp2p_swarm:opts(TID), [?MODULE, nat], true) of
        true ->
            spawn_nat_discovery(Handler, MultiAddrs, libp2p_swarm:swarm(TID));
        _ ->
            lager:notice("nat is disabled"),
            ok
    end.

spawn_nat_discovery(Handler, MultiAddrs, Swarm) ->
    case lists:filtermap(fun(M) -> case tcp_addr(M) of
                                       {IP, Port, inet, _} ->
                                           case rfc1918(IP) of
                                               false -> false;
                                               _ -> {true, {M, IP, Port}}
                                           end;
                                       _ -> false
                                   end
                         end, MultiAddrs) of
        [] -> ok;
        [Tuple|_] ->
            %% TODO we should make a port mapping for EACH address
            %% here, for weird multihomed machines, but natupnp_v1 and
            %% natpmp don't support issuing a particular request from
            %% a particular interface yet
            spawn(fun() -> try_nat(Handler, Tuple, Swarm) end)
    end.

try_nat(Handler, {MultiAddr, _IP, Port}, Swarm) ->
    case nat:discover() of
        {ok, Context} ->
            case nat:add_port_mapping(Context, tcp, Port, Port, 3600) of
                {ok, _Since, Port, Port, _MappingLifetime} ->
                    ExternalAddress = nat_external_address(Context),
                    Handler ! {record_listen_addr, MultiAddr, to_multiaddr({ExternalAddress, Port})},
                    ok;
                {error, _Reason} ->
                    lager:warning("unable to add nat mapping: ~p", [_Reason]),
                    libp2p_relay:init(Swarm),
                    ok
            end;
        _ ->
            lager:info("no nat discovered"),
            libp2p_relay:init(Swarm),
            ok
    end.

nat_external_address(Context) ->
    {ok, ExtAddress} = nat:get_external_address(Context),
    {ok, ParsedExtAddress} = inet_parse:address(ExtAddress),
    ParsedExtAddress.

%mask_address(_, _) ->
    %% presumably ipv6, don't have a function for that one yet
    %undefined.

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

try_nat_success_test() ->
    meck:new(nat, []),
    meck:expect(nat, discover, fun() -> {ok, empty} end),
    meck:expect(nat, add_port_mapping, fun(_, _, P1, P2, T) -> {ok, 0, P1, P2, T} end),
    meck:expect(nat, get_external_address, fun(_) -> {ok, "11.10.0.89"} end),

    ok = try_nat(self(), {multiaddr, ip, 8080}, swarm),

    receive
        Msg ->
            ?assertMatch({record_listen_addr, multiaddr, "/ip4/11.10.0.89/tcp/8080"}, Msg)
    after 100 ->
        ?assert(false)
    end,

    ?assert(meck:validate(nat)),
    meck:unload(nat).

try_nat_fail_test() ->
    meck:new(nat, []),
    meck:expect(nat, discover, fun() -> {error, empty} end),

    meck:new(libp2p_relay, []),
    meck:expect(libp2p_relay, init, fun(_) -> ok end),

    ok = try_nat(self(), {multiaddr, ip, 8080}, swarm),

    ?assert(meck:called(libp2p_relay, init, [swarm])),

    ?assert(meck:validate(nat)),
    ?assert(meck:validate(libp2p_relay)),
    meck:unload(nat).

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


nat_external_address_test() ->
    meck:new(nat, []),
    meck:expect(nat, get_external_address, fun(_) -> {ok, "11.10.0.89"} end),

    ?assertEqual({11, 10, 0, 89}, nat_external_address(0)),

    ?assert(meck:validate(nat)),
    meck:unload(nat).

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
