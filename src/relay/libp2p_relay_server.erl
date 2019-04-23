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
    stop/1,
    connection_lost/1
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
    swarm :: pid() | undefined,
    address :: libp2p_crypto:pubkey_bin() | undefined,
    started = false :: boolean(),
    connection :: pid() | undefined
}).

-type state() :: #state{}.

-define(FLAP_LIMIT, 3).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec relay(pid()) -> {ok, pid()} | {error, any()} | ignore.
relay(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:call(Pid, init_relay);
        {error, _}=Error ->
            Error
    end.

-spec connection_lost(pid()) -> ok.
connection_lost(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:cast(Pid, connection_lost);
        {error, _}=Error ->
            Error
    end.

-spec stop(pid()) -> ok | {error, any()}.
stop(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            %% it's a permanant worker, so just stop it and let it restart
            %% without having relay() called on it
            gen_server:stop(Pid),
            ok;
        {error, _}=Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(TID) ->
    lager:debug("~p init with ~p", [?MODULE, TID]),
    Swarm = libp2p_swarm:swarm(TID),
    true = libp2p_config:insert_relay(TID, self()),
    {ok, #state{tid=TID, swarm=Swarm}}.

handle_call(init_relay, _From, #state{started=false, swarm=Swarm}=State0) ->
    SwarmAddr = libp2p_swarm:pubkey_bin(Swarm),
    Peers = case State0#state.peers of
                [] ->
                    Peerbook = libp2p_swarm:peerbook(Swarm),
                    ok = libp2p_peerbook:join_notify(Peerbook, self()),
                    lager:debug("joined peerbook ~p notifications", [Peerbook]),
                    Peers0 = libp2p_peerbook:values(Peerbook),
                    lists:filter(fun(E) ->
                                         libp2p_peer:pubkey_bin(E) /= SwarmAddr
                                 end, Peers0);
                _ ->
                    State0#state.peers
            end,
    State = State0#state{peers=sort_peers(Peers, SwarmAddr), address=SwarmAddr},
    case int_relay(State) of
        {ok, _}=Resp ->
            lager:debug("relay started successfuly"),
            {reply, Resp, add_flap(State#state{started=true})};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            erlang:send_after(2500, self(), try_relay),
            {reply, _Error, next_peer(State)}
    end;
handle_call(init_relay, _From, State) ->
    {reply, {error, already_started}, State};
handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(connection_lost, State) ->
    lager:debug("relay connection lost"),
    self() ! try_relay,
    {noreply, State#state{started=false, connection=undefined}};
handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({new_peers, NewPeers}, #state{started=true}=State) ->
    {noreply, State#state{peers=sort_peers(merge_peers(NewPeers, State#state.peers), State#state.address), peer_index=1}};
handle_info({new_peers, NewPeers}, #state{started=false}=State) ->
    self() ! try_relay,
    {noreply, State#state{peers=sort_peers(merge_peers(NewPeers, State#state.peers), State#state.address)}};
handle_info(try_relay, State = #state{started=false}) ->
    case int_relay(State) of
        {ok, Connection} ->
            lager:debug("relay started successfuly"),
            {noreply, add_flap(State#state{started=true, connection=Connection})};
        {error, no_peer} ->
            lager:warning("could not initiate relay no peer found"),
            {noreply, State};
        {error, no_address} ->
            lager:warning("could not initiate relay, swarm has no listen address"),
            {noreply, State};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            % TODO: exponential back off here?
            erlang:send_after(2500, self(), try_relay),
            {noreply, next_peer(State)}
    end;
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{tid=TID, connection=Connection}=_State) ->
    case Connection of
        undefined -> ok;
        Pid ->
            %% stop any active relay connection so that the listen address is removed from the peerbook
            catch libp2p_framed_stream:close(Pid)
    end,
    true = libp2p_config:remove_relay(TID),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
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

-spec int_relay(state()) -> {ok, pid()} | {error, any()} | ignore.
int_relay(#state{peers=[]}) ->
    {error, no_peer};
int_relay(State=#state{swarm=Swarm}) ->
    lager:debug("init relay for swarm ~p", [libp2p_swarm:name(Swarm)]),
    Peer = lists:nth(State#state.peer_index, State#state.peers),
    Address = libp2p_crypto:pubkey_bin_to_p2p(libp2p_peer:pubkey_bin(Peer)),
    lager:debug("initiating relay with peer ~p (~b/~b)", [Address, State#state.peer_index, length(State#state.peers)]),
    libp2p_relay:dial_framed_stream(Swarm, Address, []).

-spec sort_peers([libp2p_peer:peer()], libp2p_crypto:pubkey_bin()) -> [libp2p_peer:peer()].
sort_peers(Peers0, SwarmAddr) ->
    Peers = lists:filter(fun(E) ->
        libp2p_peer:pubkey_bin(E) /= SwarmAddr
    end, Peers0),
    lists:sort(fun sort_peers_fun/2, Peers).

-spec sort_peers_fun(libp2p_peer:peer(), libp2p_peer:peer()) -> boolean().
sort_peers_fun(A, B) ->
    TypeA = libp2p_peer:nat_type(A),
    TypeB= libp2p_peer:nat_type(B),
    LengthA = erlang:length(libp2p_peer:connected_peers(A)),
    LengthB = erlang:length(libp2p_peer:connected_peers(A)),
    case {TypeA, TypeB} of
        {X, X} ->
            LengthA >= LengthB;
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

%% merge new peers into old peers based on their address
merge_peers(NewPeers, OldPeers) ->
    maps:values(maps:merge(maps:from_list([{libp2p_peer:pubkey_bin(P), P} || P <- NewPeers]),
                           maps:from_list([{libp2p_peer:pubkey_bin(P), P} || P <- OldPeers]))).

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
