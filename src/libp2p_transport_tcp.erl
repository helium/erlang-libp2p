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

%% List of non-publicly routable IP address blocks in CIDR notation: {IP, bits in mask}.
%% source: https://team-cymru.com/community-services/bogon-reference/bogon-reference-http/ (29 July 2021)
-define(BOGON_PREFIXES, [{{0, 0, 0, 0}, 8},
                         {{10, 0, 0, 0}, 8},
                         {{100, 64, 0, 0}, 10},
                         {{127, 0, 0, 0}, 8},
                         {{169, 254, 0, 0}, 16},
                         {{172, 16, 0, 0}, 12},
                         {{192, 0, 0, 0}, 24},
                         {{192, 0, 2, 0}, 24},
                         {{192, 168, 0, 0}, 16},
                         {{198, 18, 0, 0}, 15},
                         {{198, 51, 100, 0}, 24},
                         {{203, 0, 113, 0}, 24},
                         {{224, 0, 0, 0}, 4},
                         {{240, 0, 0, 0}, 4}
                        ]).

-export_type([opt/0, listen_opt/0]).

%% libp2p_transport
-export([start_listener/2, new_connection/1, new_connection/2,
         connect/5, match_addr/1, match_addr/2, sort_addrs/1]).

%% gen_server
-export([start_link/1, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).

%% libp2p_connection
-export([send/3, recv/3, acknowledge/2, addr_info/1,
         close/1, close_state/1, controlling_process/2,
         session/1, fdset/1, socket/1, fdclr/1, monitor/1,
         set_idle_timeout/2
        ]).

%% for tcp sockets
-export([to_multiaddr/1, common_options/0, tcp_addr/1, bogon_ip_mask/1, is_public/1]).

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
         observed_addrs=sets:new() :: sets:set({string(), string()}),
         negotiated_nat=false :: boolean(),
         resolved_addresses = [],
         nat_type = unknown,
         nat_server :: undefined | {reference(), pid()},
         relay_monitor = make_ref() :: reference(),
         relay_retry_timer = make_ref() :: reference(),
         stungun_timer = make_ref() :: reference(),
         stungun_timeout_count = 0 :: non_neg_integer()
        }).

-define(DEFAULT_MAX_TCP_CONNECTIONS, 1024).
-define(DEFAULT_MAX_TCP_ACCEPTORS, 10).

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


-spec match_addr(string()) -> {ok, string()} | false.
match_addr(Addr) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(Addr)).

-spec match_addr(string(), ets:tab()) -> {ok, string()} | false.
match_addr(Addr, _TID) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(Addr)).

-spec sort_addrs([string()]) -> [{integer(), string()}].
sort_addrs(Addrs) ->
    AddressesForDefaultRoutes = [ A || {ok, A} <- [catch inet_parse:address(inet_ext:get_internal_address(Addr)) || {_Interface, Addr} <- inet_ext:gateways(), Addr /= [], Addr /= undefined]],
    sort_addrs(Addrs, AddressesForDefaultRoutes).

-spec sort_addrs([string()], [inet:ip_address()]) -> [{integer(), string()}].
sort_addrs(Addrs, AddressesForDefaultRoutes) ->
    AddrIPs = lists:filtermap(fun(A) ->
        case tcp_addr(A) of
            {error, _} -> false;
            {IP, _, _, _} -> {true, {A, IP}}
        end
    end, Addrs),
    SortedAddrIps = lists:sort(fun({_, AIP}, {_, BIP}) ->
        AIP_Bogon = not (false == ?MODULE:bogon_ip_mask(AIP)),
        BIP_Bogon = not (false == ?MODULE:bogon_ip_mask(BIP)),
        case AIP_Bogon == BIP_Bogon of
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
            %% Different, A <= B if B is a non-public addr but A is not
            false ->
                BIP_Bogon andalso not AIP_Bogon
        end
    end, AddrIPs),
    lists:map(
        fun({Addr, IP}) ->
            case ?MODULE:bogon_ip_mask(IP) of
                false -> {1, Addr};
                _ -> {4, Addr}
            end
        end,
        SortedAddrIps
    ).

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
    %% apparently this can also block forever, which is bad
    %% we add receive timeouts to fdset/fdclr to compensate
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
    receive 
        {'DOWN', _Ref, process, Parent, _Reason} ->
            ok;
        {Ref, clear} ->
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
                      receive {'DOWN', _Ref, process, Parent, _Reason} ->
                                  ok;
                              {Ref, fdset} ->
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
            Pid = erlang:spawn(fun() ->
                                   erlang:put(fsset_for, Parent),
                                   erlang:monitor(process, Parent),
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
                                %% flush any other response
                                %% we might be racing with
                                receive
                                    {Ref, _} ->
                                        ok
                                after 0 ->
                                          ok
                                end,
                                {error, Reason}
                    after 5000 ->
                              %% client process wedged, kill it
                              erlang:demonitor(Ref, [flush]),
                              erlang:exit(Pid, kill),
                              erlang:put(fdset_pid, undefined),
                              fdset(State)
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
                    after 5000 ->
                              %% client process wedged, kill it
                              erlang:demonitor(Ref, [flush]),
                              erlang:exit(Pid, kill),
                              erlang:put(fdset_pid, undefined),
                              ok
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

-spec set_idle_timeout(tcp_state(), pos_integer() | infinity) -> ok | {error, term()}.
set_idle_timeout(#tcp_state{}, _Timeout) ->
    {error, not_implemented}.

-spec controlling_process(tcp_state(), pid())
                         ->  {ok, tcp_state()} | {error, closed | not_owner | atom()}.
controlling_process(State=#tcp_state{socket=Socket}, Pid) ->
    case gen_tcp:controlling_process(Socket, Pid) of
        ok -> {ok, State#tcp_state{session=Pid}};
        Other -> Other
    end.

%% this is faked out because it's already handled in framed stream,
%% which is the only user of monitor
monitor(_) ->
    make_ref().

-spec common_options() -> [term()].
common_options() ->
    [binary, {active, false}, {packet, raw}].

-spec tcp_addr(string() | multiaddr:multiaddr())
              -> {inet:ip_address(), non_neg_integer(), inet | inet6, [any()]} | {error, term()}.
tcp_addr(MAddr) ->
    tcp_addr(MAddr, multiaddr:protocols(MAddr)).

%% return net mask bits for IP in bogon prefix list or false if not in list
-spec bogon_ip_mask(inet:ip_address() | string()) -> pos_integer() | false.
bogon_ip_mask(MA) when is_list(MA) ->
    case tcp_addr(MA) of
        {IP, _Port, inet, _} ->
            case bogon_ip_mask(IP) of
                false -> false;
                R -> R
            end;
        _ -> false
    end;
bogon_ip_mask(IP) ->
    case erlang:size(IP) of
        4 ->
            %% IPv4. Sort list by longest prefix to return most specific match
            bogon_ip_mask(lists:reverse(lists:keysort(2,?BOGON_PREFIXES)), IP);
        _ ->
            %% TO-DO handle case of 8 for IPv6
            false
    end.

bogon_ip_mask([{BogonIP, BogonMask} | Tail], IP) ->
    case mask_address(BogonIP, BogonMask) == mask_address(IP, BogonMask) of
        true ->
             BogonMask;
        false ->
             bogon_ip_mask(Tail, IP)
    end;
bogon_ip_mask([],_) ->
    false.

-spec is_public(string()) -> boolean().
is_public(Address) ->
    case ?MODULE:match_addr(Address) of
        false -> false;
        {ok, _} ->
            case ?MODULE:tcp_addr(Address) of
                {IP, _, _, _} ->
                    case ?MODULE:bogon_ip_mask(IP) of
                        false -> true;
                        _ -> false
                    end;
                _ ->
                    false
            end
    end.

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

    %% find all the listen addrs owned by this transport
    ListenAddrs = [ LA || LA <- libp2p_config:listen_addrs(TID), match_addr(LA, TID) /= false ],
    %% find the distinct list if listen pids
    ListenPids = lists:foldl(fun(LA, Acc) ->
                                     case libp2p_config:lookup_listener(TID, LA) of
                                         {ok, Pid} ->
                                             case lists:member(Pid, Acc) of
                                                 true ->
                                                     Acc;
                                                 false ->
                                                     [Pid | Acc]
                                             end;
                                         false ->
                                             Acc
                                     end
                             end, [], ListenAddrs),
    %% monitor all the listen pids
    [ erlang:monitor(process, Pid) || Pid <- ListenPids],

    {ok, #state{tid=TID}}.

%% libp2p_transport
%%
handle_call({start_listener, Addr}, _From, State=#state{tid=TID}) ->
    Response =
        case listen_on(Addr, TID) of
            {ok, ListenAddrs, Socket, Pid} ->
                erlang:monitor(process, Pid),
                libp2p_nat:maybe_spawn_discovery(self(), ListenAddrs, TID),
                libp2p_config:insert_listener(TID, ListenAddrs, Pid),
                libp2p_config:insert_listen_socket(TID, Pid, Addr, Socket),
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
    {_LocalAddr, PeerAddr} = libp2p_session:addr_info(State#state.tid, Session),
    lager:notice("session identification failed for ~p: ~p", [PeerAddr, Error]),
    {noreply, State};
handle_info({handle_identify, Session, {ok, Identify}}, State) ->
    try do_identify(Session, Identify, State) of
        Result ->
            Result
    catch
        What:Why:Stack ->
            %% connection probably died
            lager:notice("handle identify failed ~p ~p ~p", [What, Why, Stack]),
            {noreply, State}
    end;
handle_info({stungun_retry,Addr}, State) ->
    handle_info(stungun_retry, State#state{resolved_addresses = State#state.resolved_addresses -- [{failed, Addr}]});
handle_info(stungun_retry, State=#state{observed_addrs=Addrs, tid=TID, stun_txns=StunTxns}) ->
    case most_observed_addr(Addrs) of
        {ok, ObservedAddr} ->
            {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(),
            %% choose a random connected peer to do stungun with
            {ok, MyPeer} = libp2p_peerbook:get(libp2p_swarm:peerbook(TID), libp2p_swarm:pubkey_bin(TID)),
            case [libp2p_crypto:pubkey_bin_to_p2p(P) || P <- libp2p_peer:connected_peers(MyPeer), libp2p_peer:has_public_ip(P)] of
                [] ->
                    %% no connected peers
                    Ref = erlang:send_after(30000, self(), stungun_retry),
                    {noreply, State#state{stungun_timer=Ref}};
                MyConnectedPeers ->
                    PeerAddr = lists:nth(rand:uniform(length(MyConnectedPeers)), MyConnectedPeers),
                    lager:info("retrying stungun with peer ~p", [PeerAddr]),
                    case libp2p_stream_stungun:dial(TID, PeerAddr, PeerPath, TxnID, self()) of
                        {ok, StunPid} ->
                            %% TODO: Remove this once dial stops using start_link
                            unlink(StunPid),
                            %% this timeout gets ignored if the txnid is cleared
                            erlang:send_after(60000, self(), {stungun_timeout, TxnID}),
                            {noreply, State#state{stun_txns=add_stun_txn(TxnID, ObservedAddr, StunTxns)}};
                        _ ->
                            Ref = erlang:send_after(30000, self(), stungun_retry),
                            {noreply, State#state{stungun_timer=Ref}}
                    end
            end;
        error ->
            %% we need at least 3 peers to agree on the observed address/port
            %% which means that port mapping discovery failed and we should retry that here
            Peers = sets:to_list(State#state.observed_addrs), 
            {PeerAddr, ObservedAddr} = lists:nth(rand:uniform(length(Peers)), Peers),
            NewState = attempt_port_forward_discovery(ObservedAddr, PeerAddr, State),
            {noreply, NewState}
    end;
handle_info({stungun_nat, TxnID, NatType}, State=#state{tid=TID, stun_txns=StunTxns}) ->
    case maps:find(TxnID, StunTxns) of
        error ->
            lager:debug("unknown stungun txnid ~p", [TxnID]),
            {noreply, State};
        {ok, ResolvedAddr} ->
            lager:info("stungun detected NAT type ~p", [NatType]),
            case NatType of
                none ->
                    %% don't clear the txn id yet we might still be waiting for the stungun_reply msg
                    %% which we need to actually complete
                    {noreply, State};
                unknown ->
                    %% stungun failed to resolve, so we have to retry later when the timeout fires
                    {noreply, State};
                _ ->
                    %% there are cases where the router uses the same outbound port for outbound dials
                    %% but there's a port map set up. This can confuse the address resolution and lead to the
                    %% outbound port detecting symmetric NAT and the inbound port detecting a working inbound
                    %% port mapping. This will yield a peerbook entry with both an external address and a relay address.
                    %%
                    %% Instead, let's check if we've resolved an external address with the same IP here before
                    %% declaring failure:

                    [{"ip4", ResolvedIPAddress}, {"tcp", _}] = multiaddr:protocols(ResolvedAddr),
                    case lists:any(fun({resolved, Addr}) ->
                                           case multiaddr:protocols(Addr) of
                                               [{"ip4", ResolvedIPAddress}, {tcp, _}] ->
                                                   true;
                                               _ ->
                                                   false
                                           end;
                                      (_) -> false
                                   end, State#state.resolved_addresses) of
                        true ->
                            lager:info("Discarding failed stungun resolution for ~p because we have resolved a working port map for this address", [ResolvedIPAddress]),
                            erlang:cancel_timer(State#state.stungun_timer),
                            {noreply, State#state{resolved_addresses=[{failed, ResolvedAddr}|State#state.resolved_addresses]}};
                        false ->
                            %% we have either port restricted cone NAT or symmetric NAT
                            %% and we need to start a relay
                            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), NatType),
                            Ref = monitor_relay_server(State),
                            libp2p_relay:init(libp2p_swarm:swarm(TID)),
                            erlang:cancel_timer(State#state.stungun_timer),
                            %% however, lets also check for a static port forward here
                            Peers = sets:to_list(State#state.observed_addrs),
                            {PeerAddr, ObservedAddr} = lists:nth(rand:uniform(length(Peers)), Peers),
                            %% finally, as this is a 'negative' result, schedule a retry in the future in case
                            %% our peers are wrong or lying to us
                            TimerRef = erlang:send_after(timer:minutes(30), self(), {stungun_retry, ResolvedAddr}),
                            NewState = attempt_port_forward_discovery(ObservedAddr, PeerAddr, State#state{stun_txns=remove_stun_txn(TxnID, StunTxns),
                                                                                                          relay_monitor = Ref,
                                                                                                          stungun_timeout_count = 0,
                                                                                                          stungun_timer = TimerRef,
                                                                                                          nat_type=NatType,
                                                                                                          resolved_addresses=[{failed, ResolvedAddr}|State#state.resolved_addresses]}),
                            {noreply, NewState}
                    end
            end
    end;
handle_info({stungun_timeout, TxnID}, State=#state{stun_txns=StunTxns, tid=TID, stungun_timeout_count=Count}) ->
    case maps:is_key(TxnID, StunTxns) of
        true ->
            lager:debug("stungun timed out"),
            Ref = erlang:send_after(30000, self(), stungun_retry),
            %% note we only remove the txnid here, because we can get multiple messages
            %% for this txnid
            NewState = State#state{stun_txns=remove_stun_txn(TxnID, StunTxns), stungun_timer=Ref, stungun_timeout_count=Count+1},
            case NewState#state.stungun_timeout_count == 5 of
                true ->
                    lager:notice("stungun timed out 5 times, adding relay address"),
                    %% we are having trouble determining our NAT type, fire up a relay in
                    %% desperation. If stungun finally resolves we will stop the relay later.
                    RelayRef = monitor_relay_server(State),
                    libp2p_relay:init(libp2p_swarm:swarm(TID)),
                    {noreply, NewState#state{relay_monitor=RelayRef}};
                false ->
                    {noreply, NewState}
            end;
        false ->
            {noreply, State}
    end;
handle_info({stungun_reply, TxnID, LocalAddr}, State=#state{tid=TID, stun_txns=StunTxns}) ->
    case maps:find(TxnID, StunTxns) of
        error ->
            lager:debug("unknown stungun txnid ~p", [TxnID]),
            {noreply, State};
        {ok, ObservedAddr} ->
            lager:info("Got dial back confirmation of observed address ~p", [ObservedAddr]),
            %% confirm it's an IP we seem to actually have
            case confirm_external_ip(ObservedAddr) of
                true ->
                    case libp2p_config:lookup_listener(TID, LocalAddr) of
                        {ok, ListenerPid} ->
                            %% remove any prior stungun discovered addresses, if any
                            [ true = libp2p_config:remove_listener(TID, MultiAddr) || {resolved, MultiAddr} <- State#state.resolved_addresses ],
                            libp2p_config:insert_listener(TID, [ObservedAddr], ListenerPid),
                            %% don't need to start relay here, stop any we already have
                            libp2p_relay_server:stop(libp2p_swarm:swarm(TID)),
                            demonitor_relay_server(State),
                            %% if we didn't have an external address originally, set the NAT type to 'static'
                            NatType = case State#state.negotiated_nat of
                                          true ->
                                              static;
                                          false ->
                                              none
                                      end,
                            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), NatType),
                            erlang:cancel_timer(State#state.stungun_timer),
                            ResolvedAddrs = [E || {resolved, _MultiAddr}=E <- State#state.resolved_addresses ],
                            %% clear the txnid so the timeout won't fire
                            {noreply, State#state{stun_txns=remove_stun_txn(TxnID, StunTxns),
                                                  nat_type=NatType,
                                                  stungun_timeout_count=0,
                                                  resolved_addresses=[{resolved, ObservedAddr}|State#state.resolved_addresses -- ResolvedAddrs]}};
                        false ->
                            %% don't clear the txnid so the stungun timeout will still be handled
                            lager:notice("unable to determine listener pid for ~p", [LocalAddr]),
                            {noreply, State}
                    end;
                false ->
                    lager:notice("no independent confirmation of external address ~p", [ObservedAddr]),
                    {noreply, State}
            end
    end;
handle_info({nat_discovered, InternalAddr, ExternalAddr}, State=#state{tid=TID}) ->
    case libp2p_config:lookup_listener(TID, InternalAddr) of
        {ok, ListenPid} ->
            lager:info("added port mapping from ~s to ~s", [InternalAddr, ExternalAddr]),
            %% remove any observed addresses
            [ true = libp2p_config:remove_listener(TID, MultiAddr) || MultiAddr <- distinct_observed_addrs(State#state.observed_addrs) ],
            libp2p_config:insert_listener(TID, [ExternalAddr], ListenPid),
            %% monitor the nat server, so we can unset this if it crashes
            {ok, Pid} = libp2p_config:lookup_nat(TID),
            Ref = erlang:monitor(process, Pid),
            %% if the nat type has resolved to 'none' here we should change it to static
            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), static),

            {noreply, State#state{negotiated_nat = true,
                                  nat_type = static,
                                  observed_addrs = sets:new(),
                                  nat_server = {Ref, Pid}}};
        _ ->
            lager:warning("no listener detected for ~p", [InternalAddr]),
            {noreply, State}
    end;
handle_info(no_nat, State) ->
    {noreply, State#state{negotiated_nat = false}};
handle_info({'DOWN', Ref, process, Pid, _Reason}, State=#state{nat_server = {NatRef, NatPid}})
  when Pid == NatPid andalso Ref == NatRef ->
    {noreply, State#state{nat_server = undefined, negotiated_nat = false, nat_type=unknown}};
handle_info({'DOWN', Ref, process, Pid, Reason}, State=#state{relay_monitor=Ref}) ->
    lager:warning("Relay server ~p crashed with reason ~p", [Pid, Reason]),
    self() ! relay_retry,
    {noreply, State};
handle_info(relay_retry, State = #state{tid = TID}) ->
    case libp2p_config:lookup_relay(TID) of
        {ok, _Pid} ->
            Ref = monitor_relay_server(State),
            libp2p_relay:init(libp2p_swarm:swarm(TID)),
            {noreply, State#state{relay_monitor=Ref}};
        false ->
            TimerRef = erlang:send_after(30000, self(), relay_retry),
            {noreply, State#state{relay_retry_timer=TimerRef}}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, State=#state{tid=TID}) when Reason /= normal; Reason /= shutdown ->
    %% check if this is a listen socket pid
    case libp2p_config:lookup_listen_socket(TID, Pid) of
        {ok, {ListenAddr, Socket}} ->
            libp2p_config:remove_listen_socket(TID, Pid),
            %% we should restart the listener here because we have not been told to *not*
            %% listen on this address
            case listen_on(ListenAddr, TID) of
                {ok, ListenAddrs, Socket, Pid} ->
                    lager:debug("restarted listener for ~p as ~p", [ListenAddr, Pid]),
                    erlang:monitor(process, Pid),
                    libp2p_nat:maybe_spawn_discovery(self(), ListenAddrs, TID),
                    libp2p_config:insert_listener(TID, ListenAddrs, Pid),
                    libp2p_config:insert_listen_socket(TID, Pid, ListenAddr, Socket),
                    Server = libp2p_swarm_sup:server(TID),
                    gen_server:cast(Server, {register, libp2p_config:listener(), Pid});
                {error, Error} ->
                    lager:error("unable to restart listener for ~p : ~p", [ListenAddr, Error])
            end;
        false ->
            ok
    end,
    {noreply, State};
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
                      {backlog, application:get_env(libp2p, listen_backlog, 1024)},
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


-spec listen_on(string(), ets:tab()) -> {ok, [string()], gen_tcp:socket(), pid()} | {error, term()}.
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
                    ok = libp2p_cache:insert(Cache, {tcp_local_listen_addrs, Type}, ListenAddrs),

                    MaxTCPConnections = application:get_env(libp2p, max_tcp_connections, ?DEFAULT_MAX_TCP_CONNECTIONS),
                    MaxAcceptors = application:get_env(libp2p, num_tcp_acceptors, ?DEFAULT_MAX_TCP_ACCEPTORS),
                    ChildSpec = ranch:child_spec(ListenAddrs,
                                                 ranch_tcp, [{socket, Socket}, {max_connections, MaxTCPConnections},
                                                             {num_acceptors, MaxAcceptors}],
                                                 libp2p_transport_ranch_protocol, {?MODULE, TID}),
                    case supervisor:start_child(Sup, ChildSpec) of
                        {ok, Pid} ->
                            ok = gen_tcp:controlling_process(Socket, Pid),
                            {ok, ListenAddrs, Socket, Pid};
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
                {error, eaddrnotavail} when UniquePort == false ->
                    %% This will only happen if we are doing reuse port and it fails
                    %% because there's already a socket with the same SrcIP, SrcPort, DestIP, DestPort
                    %% combination (it may be in a timeout/close state). This will at least allow us to
                    %% connect while that ages out.
                    connect_to(Addr, [{unique_port, true} | UserOptions], Timeout, TID, TCPPid);
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
    case libp2p_cache:lookup(Cache, {tcp_local_listen_addrs, Type}, []) of
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
    case libp2p_cache:lookup(Cache, {tcp_local_listen_addrs, Type}, []) of
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
    case libp2p_cache:lookup(Cache, {tcp_local_listen_addrs, Type}, []) of
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

distinct_observed_addrs(Addrs) ->
    {DistinctAddresses, _} = lists:foldl(fun({Reporter, Addr}, {Addresses, Reporters}) ->
                                                 case lists:member(Reporter, Reporters) of
                                                     true ->
                                                         {Addresses, Reporters};
                                                     false ->
                                                         {[Addr|Addresses], [Reporter|Reporters]}
                                                 end
                                         end, {[], []}, sets:to_list(Addrs)),
    lists:usort(DistinctAddresses).

distinct_observed_addrs_for_ip(Addrs, ThisAddr) ->
    {DistinctAddresses, _} = lists:foldl(fun({Reporter, Addr}, {Addresses, Reporters}) ->
                                                 case lists:member(Reporter, Reporters) of
                                                     true ->
                                                         {Addresses, Reporters};
                                                     false ->
                                                         %% check it shares the same IP as the supplied address
                                                         case hd(multiaddr:protocols(Addr)) == hd(multiaddr:protocols(ThisAddr)) of
                                                             true ->
                                                                 {[Addr|Addresses], [Reporter|Reporters]};
                                                             false ->
                                                                 {Addresses, Reporters}
                                                         end
                                                 end
                                         end, {[], []}, sets:to_list(Addrs)),
    lists:usort(DistinctAddresses).

-spec record_observed_addr(string(), string(), #state{}) -> #state{}.
record_observed_addr(_, _, State=#state{negotiated_nat=true}) ->
    %% we have a upnp address, do nothing
    State;
record_observed_addr(PeerAddr, ObservedAddr, State=#state{tid=TID, observed_addrs=ObservedAddrs, stun_txns=StunTxns}) ->
    case is_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs) orelse not is_public(ObservedAddr) of
        true ->
            % this peer already told us about this observed address or its a private IP
            State;
        false ->
            % check if another peer has seen this address and we're not running a stun txn for this address
            HasStunTxn = lists:member(ObservedAddr, maps:values(StunTxns)),
            IsResolved = lists:keymember(ObservedAddr, 2, State#state.resolved_addresses),
            case is_observed_addr(ObservedAddr, ObservedAddrs) of
                true ->
                    case HasStunTxn orelse IsResolved of
                        true ->
                            %% do nothing here because we're either testing this address
                            %% or we've resolved its status
                            State;
                        false ->
                            %% ok, we have independant confirmation of an observed address
                            lager:info("received confirmation of observed address ~s from peer ~s", [ObservedAddr, PeerAddr]),
                            {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(),
                            %% Record the TxnID , then convince a peer to dial us back with that TxnID
                            %% then that handler needs to forward the response back here, so we can add the external address
                            lager:info("attempting to discover network status for ~p using stungun with ~p", [ObservedAddr, PeerAddr]),
                            case libp2p_stream_stungun:dial(TID, PeerAddr, PeerPath, TxnID, self()) of
                                {ok, StunPid} ->
                                    %% TODO: Remove this once dial stops using start_link
                                    unlink(StunPid),
                                    erlang:send_after(60000, self(), {stungun_timeout, TxnID}),
                                    State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs),
                                                stun_txns=add_stun_txn(TxnID, ObservedAddr, StunTxns)};
                                _ ->
                                    State#state{observed_addrs=add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs)}
                            end
                    end;
                false ->
                    ObservedAddresses = add_observed_addr(PeerAddr, ObservedAddr, ObservedAddrs),
                    lager:info("peer ~p informed us of our observed address ~p", [PeerAddr, ObservedAddr]),
                    %% check if we have `Limit' + 1 distinct observed addresses
                    %% make it an exact check so we don't do this constantly

                    %% also check that we have not already resolved this address. eg if we've already
                    %% established a port mapping and only later do we see the symmetric NAT on outbound
                    %% connections.
                    [{"ip4", ResolvedIPAddress}, {"tcp", _}] = multiaddr:protocols(ObservedAddr),
                    HasResolvedThisAddress = lists:any(fun({resolved, Addr}) ->
                                                               case multiaddr:protocols(Addr) of
                                                                   [{"ip4", ResolvedIPAddress}, {tcp, _}] ->
                                                                       true;
                                                                   _ ->
                                                                       false
                                                               end;
                                                          (_) -> false
                                                       end, State#state.resolved_addresses),
                    case length(distinct_observed_addrs_for_ip(ObservedAddresses, ObservedAddr)) == 3 andalso not HasResolvedThisAddress of
                        true ->
                            lager:info("Saw 3 distinct observed addresses similar to ~p assuming symmetric NAT", [ObservedAddr]),
                            libp2p_peerbook:update_nat_type(libp2p_swarm:peerbook(TID), symmetric),
                            libp2p_relay:init(libp2p_swarm:swarm(TID)),
                            %% also check if we have a port forward from the same external port to our internal port
                            %% as this is a common configuration
                            attempt_port_forward_discovery(ObservedAddr, PeerAddr, State#state{observed_addrs=ObservedAddresses});
                        false ->
                            State#state{observed_addrs=ObservedAddresses}
                    end
            end
    end.

attempt_port_forward_discovery(ObservedAddr, PeerAddr, State=#state{tid=TID, stun_txns=StunTxns}) ->
    ListenSockets = libp2p_config:listen_sockets(TID),
    %% find all the listen sockets for tcp and try to see if they have a 1:1 port mapping
    lists:foldl(fun({_Pid, MA, _Socket}, StateAcc) ->
                        case multiaddr:protocols(MA) of
                            %% don't bother with port 0 listen sockets because it's
                            %% unlikely that anyone would set up an external port map
                            %% for a randomly assigned port
                            [{"ip4", _IP}, {"tcp", PortStr}] when PortStr /= "0" ->
                                {PeerPath, TxnID} = libp2p_stream_stungun:mk_stun_txn(list_to_integer(PortStr)),
                                [{"ip4", IP}, {"tcp", _}] = multiaddr:protocols(ObservedAddr),
                                ObservedAddr1 = "/ip4/"++IP++"/tcp/"++PortStr,
                                case lists:keymember(ObservedAddr1, 2, State#state.resolved_addresses) of
                                    true ->
                                        %% we don't need to try this again
                                        StateAcc;
                                    false ->
                                        case libp2p_stream_stungun:dial(TID, PeerAddr, PeerPath, TxnID, self()) of
                                            {ok, StunPid} ->
                                                lager:info("dialed stungun peer ~p looking for validation of ~p", [PeerAddr, ObservedAddr1]),
                                                %% TODO: Remove this once dial stops using start_link
                                                unlink(StunPid),
                                                erlang:send_after(60000, self(), {stungun_timeout, TxnID}),
                                                StateAcc#state{stun_txns=add_stun_txn(TxnID, ObservedAddr1, StunTxns)};
                                            _ ->
                                                StateAcc
                                        end
                                end;
                            _ ->
                                StateAcc
                        end
                end, State, ListenSockets).


%mask_address(_, _) ->
    %% presumably ipv6, don't have a function for that one yet
    %undefined.

%% @doc Get the subnet mask as an integer, stolen from an old post on
%%      erlang-questions.
-spec mask_address(inet:ip_address(), pos_integer()) -> integer().
mask_address(Addr={_, _, _, _}, Maskbits) ->
    B = list_to_binary(tuple_to_list(Addr)),
    <<Subnet:Maskbits, _Host/bitstring>> = B,
    Subnet;
mask_address({A,B,C,D,E,F,G,H}, Maskbits) ->
    %% IPv6
    Addr = <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>,
    <<Subnet:Maskbits, _Host/bitstring>> = Addr,
    Subnet.

do_identify(Session, Identify, State=#state{tid=TID}) ->
    {LocalAddr, _PeerAddr} = libp2p_session:addr_info(State#state.tid, Session),
    RemoteP2PAddr = libp2p_crypto:pubkey_bin_to_p2p(libp2p_identify:pubkey_bin(Identify)),
    ListenAddrs = libp2p_config:listen_addrs(TID),
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
                    lager:info("Listen addresses changed: ~p -> ~p", [MyListenAddrs, NewListenAddrs]),
                    [ libp2p_config:remove_listener(TID, A) || A <- RemovedListenAddrs ],
                    %% we can simply re-add all of the addresses again, overrides are fine
                    [ libp2p_config:insert_listener(TID, LAs, P) || {LAs, P} <- NewListenAddrsWithPid],
                    libp2p_nat:maybe_spawn_discovery(self(), NewListenAddrs, TID),
                    %% wipe out any prior observed addresses here
                    {noreply, record_observed_addr(RemoteP2PAddr, ObservedAddr, State#state{observed_addrs=sets:new()} )};
                false ->
                    lager:debug("identify response with local address ~p that is not a listen addr socket ~p, ignoring",
                                [LocalAddr, NewListenAddrs]),
                    %% this is likely a discovery session we dialed with unique_port
                    %% we can't trust this for the purposes of the observed address
                    {noreply, State}
            end
    end.

monitor_relay_server(#state{relay_monitor=Ref, tid=TID}) ->
    erlang:demonitor(Ref),
    {ok, Pid} = libp2p_config:lookup_relay(TID),
    erlang:monitor(process, Pid).

demonitor_relay_server(#state{relay_monitor=Ref, relay_retry_timer=Timer}) ->
    erlang:cancel_timer(Timer),
    erlang:demonitor(Ref).

confirm_external_ip(ResolvedAddr) ->
    %% if configured, we expect a service similar to ifconfig.co
    %% that will return the IP address as a string in the body if accept: text/plain
    %% is supplied. This service is open source so vendors can run their own if rate limit
    %% issues occur. We only confirm this at the very end of the IP discovery process as
    %% a way to limit the load on the external service.
    case application:get_env(libp2p, ip_confirmation_host) of
        undefined ->
            %% no way to confirm or deny
            true;
        {ok, ResolveURL} ->
            case multiaddr:protocols(ResolvedAddr) of
                [{"ip4", ResolvedIPAddress}, {"tcp", _}] ->
                    case httpc:request(get, {ResolveURL, [{"accept", "text/plain"}]}, [{timeout, 30000}], [{socket_opts, [inet]}]) of
                        {ok, {{_, 200, _}, _, Body0}} ->
                            Body = string:chomp(Body0),
                            case inet:parse_ipv4_address(Body) of
                                {ok, _IP} ->
                                    Body == ResolvedIPAddress;
                                _ ->
                                    lager:notice("failed to parse ip resolution service response ~p", [Body]),
                                    true
                            end;
                        _ ->
                            lager:notice("resolving external address with ~p failed", [ResolveURL]),
                            %% something went wrong here, likely a rate limiting or routing issue
                            %% it's probably best to err on the side of assuming the peers are correct
                            true
                    end;
                Result ->
                    lager:notice("could not parse resolved address as ipv4/tcp ~p: ~p", [ResolvedAddr, Result]),
                    false
            end
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

bogon_ip_mask_test() ->
    ?assertEqual(8, bogon_ip_mask({0, 0, 0, 0})),
    ?assertEqual(8, bogon_ip_mask({10, 0, 0, 0})),
    ?assertEqual(8, bogon_ip_mask({10, 20, 0, 0})),
    ?assertEqual(8, bogon_ip_mask({10, 1, 1, 1})),
    ?assertEqual(16, bogon_ip_mask({192, 168, 10, 1})),
    ?assertEqual(16, bogon_ip_mask({192, 168, 20, 1})),
    ?assertEqual(16, bogon_ip_mask({192, 168, 30, 1})),
    ?assertEqual(12, bogon_ip_mask({172, 16, 1, 0})),
    ?assertEqual(12, bogon_ip_mask({172, 16, 10, 0})),
    ?assertEqual(12, bogon_ip_mask({172, 16, 100, 0})),
    ?assertEqual(10, bogon_ip_mask({100, 109, 66, 8})),
    ?assertEqual(10, bogon_ip_mask({100, 114, 44, 71})),
    ?assertEqual(8, bogon_ip_mask({127, 0, 0, 1})),
    ?assertEqual(16, bogon_ip_mask({169, 254, 0, 1})),
    ?assertEqual(15, bogon_ip_mask({198, 18, 10, 18})),
    ?assertEqual(24, bogon_ip_mask({203, 0, 113, 99})),
    ?assertEqual(4, bogon_ip_mask({224, 255, 254, 1})),
    ?assertEqual(4, bogon_ip_mask({227, 0, 0, 1})),
    ?assertEqual(4, bogon_ip_mask({240, 1, 1, 1})),
    ?assertEqual(4, bogon_ip_mask({241, 1, 1, 1})),
    ?assertEqual(false, bogon_ip_mask({11, 0, 0, 0})),
    ?assertEqual(false, bogon_ip_mask({192, 169, 10, 1})),
    ?assertEqual(false, bogon_ip_mask({172, 254, 100, 0})),
    ?assertEqual(false, bogon_ip_mask({1, 1, 1, 1})),
    ?assertEqual(false, bogon_ip_mask({100, 63, 255, 255})),
    ?assertEqual(false, bogon_ip_mask({198, 17, 0, 1})),
    ?assertEqual(false, bogon_ip_mask({209, 85, 231, 104})),
    %% IPv6 negative test
    ?assertEqual(false, bogon_ip_mask({10754,11778,33843,58112,38506,45311,65119,6184})).

sort_addr_test() ->
    Addrs = [
        "/ip4/10.0.0.0/tcp/22",
        "/ip4/207.148.0.20/tcp/100",
        "/ip4/10.0.0.1/tcp/19",
        "/ip4/192.168.1.16/tcp/18",
        "/ip4/207.148.0.21/tcp/101"
    ],
    ?assertEqual(
        [{1, "/ip4/207.148.0.20/tcp/100"},
         {1, "/ip4/207.148.0.21/tcp/101"},
         {4, "/ip4/10.0.0.0/tcp/22"},
         {4, "/ip4/10.0.0.1/tcp/19"},
         {4, "/ip4/192.168.1.16/tcp/18"}],
        sort_addrs(Addrs, [])
    ),
    %% check that 'default route' addresses sort first, within their class
    ?assertEqual(
        [{1, "/ip4/207.148.0.20/tcp/100"},
         {1, "/ip4/207.148.0.21/tcp/101"},
         {4, "/ip4/192.168.1.16/tcp/18"},
         {4, "/ip4/10.0.0.0/tcp/22"},
         {4, "/ip4/10.0.0.1/tcp/19"}],
        sort_addrs(Addrs, [{192, 168, 1, 16}])
    ),
    ok.

-endif.
