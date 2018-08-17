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
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1
    ,handle_call/3
    ,handle_cast/2
    ,handle_info/2
    ,terminate/2
    ,code_change/3
]).

-record(state, {
    tid :: ets:tab() | undefined
    ,swarm :: pid() | undefined
    ,started = false :: boolean()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(TID) ->
    lager:info("~p init with ~p", [?MODULE, TID]),
    true = libp2p_config:insert_relay(TID, self()),
    Swarm = libp2p_swarm:swarm(TID),
    {ok, #state{tid=TID, swarm=Swarm}}.

handle_call(init_relay, _From, #state{swarm=Swarm}=State) ->
    Peerbook = libp2p_swarm:peerbook(Swarm),
    ok = libp2p_peerbook:join_notify(Peerbook, self()),
    lager:info("joined peerbook ~p notifications", [Peerbook]),
    case int_relay(Swarm) of
        {ok, _}=Resp ->
            lager:info("relay started successfuly"),
            {reply, Resp, State#state{started=true}};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {reply, _Error, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({new_peers, _}, #state{started=true}=State) ->
    lager:info("relay already started ignoring new peer"),
    {noreply, State};
handle_info({new_peers, _}, #state{swarm=Swarm, started=false}=State) ->
    case int_relay(Swarm) of
        {ok, _} ->
            lager:info("relay started successfuly"),
            {noreply, State#state{started=true}};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{tid=TID}=_State) ->
    true = libp2p_config:remove_relay(TID),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec int_relay(pid()) -> {ok, pid()} | {error, any()} | ignore.
int_relay(Swarm) ->
    lager:info("init relay for swarm ~p", [libp2p_swarm:name(Swarm)]),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    Peers = libp2p_peerbook:values(Peerbook),
    SwarmAddr = libp2p_swarm:address(Swarm),
    case select_peer(SwarmAddr, Peers) of
        {error, Reason}=Error ->
            lager:warning("could not initiate relay, failed to find peer ~p", [Reason]),
            Error;
        Peer ->
            case libp2p_peer:listen_addrs(Peer) of
                [ListenAddr|_] ->
                    libp2p_relay:dial_framed_stream(Swarm, ListenAddr, []);
                _Any ->
                    lager:warning("could not initiate relay, failed to find address ~p", [_Any]),
                    {error, no_address}
            end
    end.

-spec select_peer(binary(), list()) -> libp2p_peer:peer() | list() | {error, no_peer}.
select_peer(SelfSwarmAddr, Peers) ->
    case select_peer(SelfSwarmAddr, Peers, []) of
        SelectedPeers when is_list(SelectedPeers) ->
            case lists:sort(SelectedPeers) of
                [{_, Peer}|_] -> Peer;
                _ -> {error, no_peer}
            end;
        Peer ->
            Peer
    end.

-spec select_peer(binary(), list(), list()) -> libp2p_peer:peer() | list().
select_peer(_SelfSwarmAddr, [], Acc) -> Acc;
select_peer(SelfSwarmAddr, [Peer|Peers], Acc) ->
    case libp2p_peer:address(Peer) of
        SelfSwarmAddr ->
            select_peer(SelfSwarmAddr, Peers, Acc);
        _PeerAddress ->
            case libp2p_peer:nat_type(Peer) of
                none -> Peer;
                static -> Peer;
                _ ->
                    L = erlang:length(libp2p_peer:connected_peers(Peer)),
                    select_peer(SelfSwarmAddr, Peers, [{L, Peer}|Acc])
            end
    end.
