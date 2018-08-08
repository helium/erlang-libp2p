%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
    ,init_relay/1
    ,version/0
    ,add_stream_handler/1
    ,dial_framed_stream/3
    ,p2p_circuit/1, p2p_circuit/2, is_p2p_circuit/1
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(RELAY_VERSION, "relay/1.0.0").
-define(P2P_CIRCUIT, "/p2p-circuit").

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

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec init_relay(pid()) -> {ok, pid()} | {error, any()} | ignore.
init_relay(Swarm) ->
    TID = libp2p_swarm:tid(Swarm),
    case libp2p_config:lookup_relay(TID) of
        false -> {error, no_relay};
        {ok, Pid} ->
            gen_server:call(Pid, init_relay)
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec version() -> string().
version() ->
    ?RELAY_VERSION.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(ets:tab()) -> ok.
add_stream_handler(TID) ->
    libp2p_swarm:add_stream_handler(
        TID
        ,?RELAY_VERSION
        ,{libp2p_framed_stream, server, [libp2p_stream_relay, self(), TID]}
    ).

%%--------------------------------------------------------------------
%% @doc
%% Dial relay stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(pid(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(Swarm, Address, Args) ->
    Args1 = [
        {swarm, Swarm}
    ],
    libp2p_swarm:dial_framed_stream(
        Swarm
        ,Address
        ,?RELAY_VERSION
        ,libp2p_stream_relay
        ,Args ++ Args1
    ).

%%--------------------------------------------------------------------
%% @doc
%% Split p2p circuit address
%% @end
%%--------------------------------------------------------------------
-spec p2p_circuit(string()) -> {ok, {string(), string()}} | error.
p2p_circuit(P2PCircuit) ->
    case string:split(P2PCircuit, ?P2P_CIRCUIT) of
        [R, A] -> {ok, {R, A}};
        _ -> error
    end.

%%--------------------------------------------------------------------
%% @doc
%% Create p2p circuit address
%% @end
%%--------------------------------------------------------------------
-spec p2p_circuit(string(), string()) -> string().
p2p_circuit(R, A) ->
    R ++ ?P2P_CIRCUIT ++ A.

%%--------------------------------------------------------------------
%% @doc
%% Split p2p circuit address
%% @end
%%--------------------------------------------------------------------
-spec is_p2p_circuit(string()) -> boolean().
is_p2p_circuit(Address) ->
    case string:find(Address, ?P2P_CIRCUIT) of
        nomatch -> false;
        _ -> true
    end.

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
    case init_relay_for_swarm(Swarm) of
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
    case init_relay_for_swarm(Swarm) of
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

-spec init_relay_for_swarm(pid()) -> {ok, pid()} | {error, any()} | ignore.
init_relay_for_swarm(Swarm) ->
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
                    ?MODULE:dial_framed_stream(Swarm, ListenAddr, []);
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


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

p2p_circuit_1_test() ->
    ?assertEqual(
        {ok, {"/ip4/192.168.1.61/tcp/6601", "/ip4/192.168.1.61/tcp/6600"}}
        ,p2p_circuit("/ip4/192.168.1.61/tcp/6601/p2p-circuit/ip4/192.168.1.61/tcp/6600")
    ),
    ok.

p2p_circuit_2_test() ->
    ?assertEqual("/abc/p2p-circuit/def", p2p_circuit("/abc", "/def")),
    ok.

is_p2p_circuit_test() ->
    ?assert(is_p2p_circuit("/ip4/192.168.1.61/tcp/6601/p2p-circuit/ip4/192.168.1.61/tcp/6600")),
    ?assertNot(is_p2p_circuit("/ip4/192.168.1.61/tcp/6601")),
    ?assertNot(is_p2p_circuit("/ip4/192.168.1.61/tcp/6601p2p-circuit/ip4/192.168.1.61/tcp/6600")),
    ok.

-endif.
