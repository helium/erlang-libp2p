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
    ,peers = []
    ,peer_index = 1
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

handle_call(init_relay, _From, #state{swarm=Swarm}=State0) ->
    State = State0#state{peers=sort_peers(Swarm)},
    Peerbook = libp2p_swarm:peerbook(Swarm),
    ok = libp2p_peerbook:join_notify(Peerbook, self()),
    lager:info("joined peerbook ~p notifications", [Peerbook]),
    case int_relay(State) of
        {ok, _}=Resp ->
            lager:info("relay started successfuly"),
            {reply, Resp, State#state{started=true}};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {reply, _Error, next_peer(State)}
    end;
handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({new_peers, _}, #state{started=true}=State) ->
    lager:info("relay already started ignoring new peer"),
    {noreply, State#state{peers=sort_peers(State#state.swarm)}};
handle_info({new_peers, _}, #state{swarm=Swarm, started=false}=State0) ->
    State = State0#state{peers=sort_peers(Swarm)},
    case int_relay(State) of
        {ok, _} ->
            lager:info("relay started successfuly"),
            {noreply, State#state{started=true}};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {noreply, next_peer(State)}
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

-spec int_relay(#state{}) -> {ok, pid()} | {error, any()} | ignore.
int_relay(#state{peers=[]}) ->
    {error, no_peer};
int_relay(State=#state{swarm=Swarm}) ->
    lager:info("init relay for swarm ~p", [libp2p_swarm:name(Swarm)]),
    Peer = lists:nth(State#state.peer_index, State#state.peers),
    case libp2p_peer:listen_addrs(Peer) of
        [ListenAddr|_] ->
            lager:info("initiating relay with ~p", [ListenAddr]),
            libp2p_relay:dial_framed_stream(Swarm, ListenAddr, []);
        _Any ->
            lager:warning("could not initiate relay, failed to find address ~p", [_Any]),
            {error, no_address}
    end.

sort_peers(Swarm) ->
    Peerbook = libp2p_swarm:peerbook(Swarm),
    Peers0 = libp2p_peerbook:values(Peerbook),
    SwarmAddr = libp2p_swarm:address(Swarm),
    Peers = lists:dropwhile(fun(E) ->
                                    libp2p_peer:address(E) == SwarmAddr
                            end, Peers0),
    lager:info("sorting peers ~p ~p", [length(Peers0), length(Peers)]),
    lists:sort(fun sort_peers_fun/2, Peers).

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

next_peer(State = #state{peers=Peers, peer_index=PeerIndex}) ->
    case PeerIndex + 1 > length(Peers) of
        true ->
            State#state{peer_index=1};
        false ->
            State#state{peer_index=PeerIndex +1}
    end.
