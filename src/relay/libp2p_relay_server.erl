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
    ,relay/1
    ,connection_lost/1
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

-type state() :: #state{}.

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
            erlang:send_after(2500, self(), try_relay),
            {reply, _Error, next_peer(State)}
    end;
handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(connection_lost, State) ->
    lager:info("relay connection lost"),
    self() ! try_relay,
    {noreply, State#state{started=false}};
handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({new_peers, _}, #state{started=true}=State) ->
    lager:info("relay already started, just adding new peer"),
    {noreply, State#state{peers=sort_peers(State#state.swarm), peer_index=1}};
handle_info({new_peers, _}, #state{swarm=Swarm, started=false}=State) ->
    self() ! try_relay,
    {noreply, State#state{peers=sort_peers(Swarm)}};
handle_info(try_relay, State = #state{started=false}) ->
    case int_relay(State) of
        {ok, _} ->
            lager:info("relay started successfuly"),
            {noreply, State#state{started=true}};
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

terminate(_Reason, #state{tid=TID}=_State) ->
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
    lager:info("init relay for swarm ~p", [libp2p_swarm:name(Swarm)]),
    Peer = lists:nth(State#state.peer_index, State#state.peers),
    Address = "/p2p/" ++ libp2p_crypto:address_to_b58(libp2p_peer:address(Peer)),
    lager:info("initiating relay with peer ~p (~b/~b)", [Address, State#state.peer_index, length(State#state.peers)]),
    libp2p_relay:dial_framed_stream(Swarm, Address, []).

-spec sort_peers(pid()) -> [libp2p_peer:peer()].
sort_peers(Swarm) ->
    Peerbook = libp2p_swarm:peerbook(Swarm),
    Peers0 = libp2p_peerbook:values(Peerbook),
    SwarmAddr = libp2p_swarm:address(Swarm),
    Peers = lists:filter(fun(E) ->
        libp2p_peer:address(E) /= SwarmAddr
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

-spec next_peer(state()) -> state().
next_peer(State = #state{peers=Peers, peer_index=PeerIndex}) ->
    case PeerIndex + 1 > length(Peers) of
        true ->
            State#state{peer_index=1};
        false ->
            State#state{peer_index=PeerIndex +1}
    end.
