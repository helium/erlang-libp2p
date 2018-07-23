%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay).

-export([
    init/1
    ,version/0
    ,add_stream_handler/1
    ,dial_framed_stream/3
    ,p2p_circuit/1, p2p_circuit/2
]).

-define(RELAY_VERSION, "relay/1.0.0").
-define(P2P_CIRCUIT, "/p2p-circuit").

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec init(pid()) -> {ok, pid()} | {error, any()} | ignore.
init(Swarm) ->
    lager:info("init relay for ~p", [libp2p_swarm:name(Swarm)]),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    Peers = libp2p_peerbook:values(Peerbook),
    SwarmAddr = libp2p_swarm:address(Swarm),
    ListenAddrs = lists:foldl(
        fun(Peer, Acc) ->
            case libp2p_peer:address(Peer) of
                SwarmAddr -> Acc;
                _PeerAddress ->
                    L = erlang:length(libp2p_peer:connected_peers(Peer)),
                    [{L, libp2p_peer:listen_addrs(Peer)}|Acc]
            end
        end
        ,[]
        ,Peers
    ),
    case lists:sort(ListenAddrs) of
        [{L, [ListenAddr|_]}|_] ->
            lager:info("found ~s with the most connection (~p)", [ListenAddr, L]),
            ?MODULE:dial_framed_stream(Swarm, ListenAddr, []);
        _Any ->
            lager:warning("could nopt initiate relay, failed to find address ~p", [_Any]),
            {error, no_address}
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
        [A, B] -> {ok, {A, B}};
        _ -> error
    end.

%%--------------------------------------------------------------------
%% @doc
%% Create p2p circuit address
%% @end
%%--------------------------------------------------------------------
-spec p2p_circuit(string(), string()) -> string().
p2p_circuit(A, B) ->
    A ++ ?P2P_CIRCUIT ++ B.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
