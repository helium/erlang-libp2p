%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay Server ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_server).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    relay/1,
    stop/1, replace/2,
    negotiated/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    tid :: ets:tab() | undefined,
    peers = [] :: [libp2p_peer:peer()],
    peer_index = 1,
    flap_count = 0,
    address :: string() | undefined,
    stream :: pid() | undefined,
    retrying = make_ref() :: reference(),
    banlist = [] :: list(),
    peerbook :: libp2p_peerbook:peerbook() | undefined
}).

-type state() :: #state{}.

-define(FLAP_LIMIT, 3).
-define(BANLIST_TIMEOUT, timer:minutes(5)).
-define(MAX_RELAY_DURATION, timer:minutes(30)).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec relay(pid()) -> ok | {error, any()}.
relay(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:cast(Pid, init_relay);
        {error, _}=Error ->
            Error
    end.

-spec stop(pid()) -> ok | {error, any()}.
stop(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:cast(Pid, stop_relay);
        {error, _}=Error ->
            Error
    end.

-spec replace(string(), pid()) -> ok | {error, any()}.
replace(Address, Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            Pid ! {replace_relay, Address};
        {error, _}=Error ->
            Error
    end.

-spec negotiated(pid(), string()) -> ok | {error, any()}.
negotiated(Swarm, Address) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:call(Pid, {negotiated, Address, self()});
        {error, _}=Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(TID) ->
    lager:info("~p init with ~p", [?MODULE, TID]),
    true = libp2p_config:insert_relay(TID, self()),
    {ok, #state{tid=TID}}.

handle_call({negotiated, Address, Pid}, _From, #state{tid=TID, stream=Pid}=State) when is_pid(Pid) ->
    true = libp2p_config:insert_listener(TID, [Address], Pid),
    lager:info("inserting new listener ~p, ~p, ~p", [TID, Address, Pid]),
    %% to ensure we don't get black-hole routed by a naughty relay, schedule a max-age we keep this relay around
    %% before trying to obtain a new one
    erlang:send_after(?MAX_RELAY_DURATION, self(), {replace_relay, Address}),
    {reply, ok, State#state{address=Address}};
handle_call({negotiated, _Address, _Pid}, _From, #state{stream=undefined}=State) ->
    lager:error("cannot insert ~p listener unknown stream (~p)", [_Address, _Pid]),
    {reply, {error, unknown_pid}, State};
handle_call({negotiated, _Address, Pid1}, _From, #state{stream=Pid2}=State) ->
    lager:error("cannot insert ~p listener wrong stream ~p (~p)", [_Address, Pid1, Pid2]),
    {reply, {error, wrong_pid}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(stop_relay, #state{stream=Pid, address=Address, tid=TID}=State) when is_pid(Pid) ->
    lager:warning("relay was asked to be stopped ~p ~p", [Pid, Address]),
    _ = libp2p_config:remove_listener(TID, Address),
    catch libp2p_framed_stream:close(Pid),
    %% don't use the banlist here, we likely disconnected because we negotiated a NAT punch
    {noreply, State#state{stream=undefined, address=undefined}};
handle_cast(stop_relay, State) ->
    %% nothing to do as we're not running
    {noreply, State};
handle_cast(init_relay, #state{tid=TID, stream=undefined}=State0) ->
    Swarm = libp2p_swarm:swarm(TID),
    SwarmPubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    Peers = case State0#state.peers of
                [] ->
                    ok = libp2p_peerbook:join_notify(Peerbook, self()),
                    lager:debug("joined peerbook ~p notifications", [Peerbook]),
                    libp2p_peerbook:values(Peerbook);
                _ ->
                    State0#state.peers
            end,
    State = State0#state{peers=sort_peers(Peers, SwarmPubKeyBin, State0), peerbook=Peerbook},
    case init_relay(State) of
        {ok, Pid} ->
            _ = erlang:monitor(process, Pid),
            lager:info("relay started successfully with ~p", [Pid]),
            {noreply, add_flap(State#state{stream=Pid, address=undefined})};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {noreply, next_peer(retry(State))}
    end;
handle_cast(init_relay,  #state{stream=Pid}=State) when is_pid(Pid) ->
    lager:info("requested to init relay but we already have one @ ~p", [Pid]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({new_peers, NewPeers}, #state{tid=TID, stream=Pid,
                                          peers=Peers, peerbook=PeerBook}=State) when is_pid(Pid) ->
    Swarm = libp2p_swarm:swarm(TID),
    SwarmPubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {noreply, State#state{peers=sort_peers(merge_peers(NewPeers, Peers, PeerBook), SwarmPubKeyBin, State), peer_index=1}};
handle_info({new_peers, NewPeers}, #state{tid=TID, peers=Peers, peerbook=PeerBook}=State) ->
    Swarm = libp2p_swarm:swarm(TID),
    SwarmPubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {noreply, State#state{peers=sort_peers(merge_peers(NewPeers, Peers, PeerBook), SwarmPubKeyBin, State)}};
handle_info(retry, #state{stream=undefined}=State) ->
    case init_relay(State) of
        {ok, Pid} ->
            _ = erlang:monitor(process, Pid),
            lager:info("relay started successfully with ~p", [Pid]),
            {noreply, add_flap(State#state{stream=Pid, address=undefined})};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {noreply, next_peer(retry(State))}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{tid=TID, stream=Pid, address=Address}=State) ->
    lager:info("Relay session with address ~p closed with reason ~p", [Address, Reason]),
    _ = libp2p_config:remove_listener(TID, Address),
    %% add it to the banlist so we temporarily avoid trying to connect to it again
    {noreply, retry(banlist(Address, State#state{stream=undefined, address=undefined}))};
handle_info({replace_relay, Address}, #state{stream=Pid, address=Address, tid=TID}=State) when is_pid(Pid) ->
    lager:warning("relay was asked to be replaced ~p ~p", [Pid, Address]),
    _ = libp2p_config:remove_listener(TID, Address),
    catch libp2p_framed_stream:close(Pid),
    %% we likely disconnected from this relay specifically because of overload or max duration
    %% so avoid immediately re-connecting to it
    {noreply, retry(banlist(Address, State#state{stream=undefined, address=undefined}))};
handle_info({replace_relay, _OtherAddress}, State) ->
    %% nothing to do as we're not running
    {noreply, State};
handle_info({unbanlist, PeerAddr}, State=#state{banlist=Banlist}) ->
    {noreply, State#state{banlist=lists:delete(PeerAddr, Banlist)}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{tid=TID, stream=Pid}) when is_pid(Pid) ->
    catch libp2p_framed_stream:close(Pid),
    true = libp2p_config:remove_relay(TID),
    ok;
terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

retry(#state{retrying=OldTimer}=State) ->
    erlang:cancel_timer(OldTimer),
    TimeRef = erlang:send_after(2500, self(), retry),
    State#state{retrying=TimeRef}.

-spec get_relay_server(pid()) -> {ok, pid()} | {error, any()}.
get_relay_server(Swarm) ->
    try libp2p_swarm:tid(Swarm) of
        TID ->
            case libp2p_config:lookup_relay(TID) of
                false -> {error, no_relay};
                {ok, _Pid}=R -> R
            end
    catch
        What:Why ->
            lager:warning("fail to get relay server ~p/~p", [What, Why]),
            {error, swarm_down}
    end.

-spec init_relay(state()) -> {ok, pid()} | {error, any()} | ignore.
init_relay(#state{peers=[]}) ->
    {error, no_peer};
init_relay(#state{tid=TID}=State) ->
    Swarm = libp2p_swarm:swarm(TID),
    lager:debug("init relay for swarm ~p", [libp2p_swarm:name(Swarm)]),
    Peer = lists:nth(State#state.peer_index, State#state.peers),
    Address = libp2p_crypto:pubkey_bin_to_p2p(libp2p_peer:pubkey_bin(Peer)),
    lager:info("initiating relay with peer ~p (~b/~b)", [Address, State#state.peer_index, length(State#state.peers)]),
    libp2p_relay:dial_framed_stream(Swarm, Address, []).

-spec sort_peers([libp2p_peer:peer()], libp2p_crypto:pubkey_bin(), #state{}) -> [libp2p_peer:peer()].
sort_peers(Peers0, SwarmPubKeyBin, State) ->
    Peers1 = lists:filter(fun(Peer) ->
        libp2p_peer:pubkey_bin(Peer) /= SwarmPubKeyBin andalso
        libp2p_peer:has_public_ip(Peer) andalso
        not lists:member(libp2p_peer:pubkey_bin(Peer), State#state.banlist)
    end, Peers0),
    lists:sort(fun sort_peers_fun/2, shuffle(Peers1)).

-spec sort_peers_fun(libp2p_peer:peer(), libp2p_peer:peer()) -> boolean().
sort_peers_fun(A, B) ->
    TypeA = libp2p_peer:nat_type(A),
    TypeB= libp2p_peer:nat_type(B),
    LengthA = erlang:length(libp2p_peer:connected_peers(A)),
    LengthB = erlang:length(libp2p_peer:connected_peers(B)),
    case {TypeA, TypeB} of
        {X, X} ->
            LengthA < LengthB;
        {none, _} ->
            true;
        {_, none} ->
            false;
        {static, _} ->
            true;
        {_, static} ->
            false;
        _ ->
            true
    end.

shuffle(List) ->
    element(2, lists:unzip(lists:sort([{rand:uniform(), E} || E <- List]))).

%% merge new peers into old peers based on their address
merge_peers(NewPeers, OldPeers, PeerBook) ->
    StaleTime = libp2p_peerbook:stale_time(PeerBook),
    Peers = maps:values(maps:merge(maps:from_list([{libp2p_peer:pubkey_bin(P), P} || P <- OldPeers]),
                                   maps:from_list([{libp2p_peer:pubkey_bin(P), P} || P <- NewPeers]))),
    lists:filter(fun(P) -> not libp2p_peer:is_stale(P, StaleTime) end, Peers).

-spec next_peer(state()) -> state().
next_peer(State = #state{peers=Peers, peer_index=PeerIndex}) ->
    case PeerIndex + 1 > length(Peers) of
        true ->
            State#state{peer_index=1};
        false ->
            State#state{peer_index=PeerIndex +1}
    end.

add_flap(State = #state{flap_count=Flaps}) ->
    case Flaps + 1 >= ?FLAP_LIMIT of
        true ->
            next_peer(State#state{flap_count=0});
        false ->
            State#state{flap_count=Flaps+1}
    end.

banlist(Address, State=#state{banlist=Banlist}) ->
    {ok, {RAddress, _SAddress}} = libp2p_relay:p2p_circuit(Address),
    PeerAddr = libp2p_crypto:p2p_to_pubkey_bin(RAddress),
    case lists:member(PeerAddr, Banlist) of
        true ->
            State;
        false ->
            erlang:send_after(?BANLIST_TIMEOUT, self(), {unbanlist, PeerAddr}),
            %% restrict the length of the banlist to 1/3 of all the available peers
            State#state{banlist=lists:sublist([PeerAddr|Banlist], length(State#state.peers) div 3)}
    end.
