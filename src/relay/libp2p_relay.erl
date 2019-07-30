%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    version/0,
    add_stream_handler/1,
    dial_framed_stream/3,
    p2p_circuit/1, p2p_circuit/2, is_p2p_circuit/1,
    reg_addr_sessions/1 ,reg_addr_sessions/2, unreg_addr_sessions/1,
    reg_addr_stream/1, reg_addr_stream/2, unreg_addr_stream/1,
    is_valid_peer/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(RELAY_VERSION, "relay/1.0.0").
-define(P2P_CIRCUIT, "/p2p-circuit").

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec init(pid()) -> ok | {error, any()}.
init(Swarm) ->
    libp2p_relay_server:relay(Swarm).

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
        TID,
        ?RELAY_VERSION,
        {libp2p_framed_stream, server, [libp2p_stream_relay, self(), TID]}
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
        Swarm,
        Address,
        ?RELAY_VERSION,
        libp2p_stream_relay,
        Args ++ Args1
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

-spec reg_addr_sessions(string()) -> atom().
reg_addr_sessions(Address) ->
    erlang:list_to_atom(Address ++ "/sessions").

-spec reg_addr_sessions(string(), pid()) -> true.
reg_addr_sessions(Address, Pid) ->
    erlang:register(?MODULE:reg_addr_sessions(Address), Pid).

-spec unreg_addr_sessions(string()) -> true.
unreg_addr_sessions(Address) ->
    erlang:unregister(?MODULE:reg_addr_sessions(Address)).

-spec reg_addr_stream(string()) -> atom().
reg_addr_stream(Address) ->
    erlang:list_to_atom(Address ++ "/stream").

-spec reg_addr_stream(string(), pid()) -> true.
reg_addr_stream(Address, Pid) ->
    RegName = ?MODULE:reg_addr_stream(Address),
    case erlang:whereis(RegName) of
        undefined ->
            ok;
        RegPid ->
            RegPid ! stop,
            _ = ?MODULE:unreg_addr_stream(Address)
    end,
    erlang:register(RegName, Pid).

-spec unreg_addr_stream(string()) -> true.
unreg_addr_stream(Address) ->
    erlang:unregister(?MODULE:reg_addr_stream(Address)).

-spec is_valid_peer(pid(), libp2p_crypto:pubkey_bin()) -> {error, any()} | boolean().
is_valid_peer(Swarm, PubKeyBin) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    case libp2p_peerbook:get(PeerBook, PubKeyBin) of
        {error, _Reason}=Error ->
            Error;
        {ok, Peer} ->
            StaleTime = libp2p_peerbook:stale_time(PeerBook),
            ConnectedPeers = libp2p_peer:connected_peers(Peer),
            not libp2p_peer:is_stale(Peer, StaleTime) andalso
            libp2p_peer:has_public_ip(Peer) andalso
            lists:member(libp2p_swarm:pubkey_bin(Swarm), ConnectedPeers)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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

reg_addr_sessions_1_test() ->
    ?assertEqual(
        '/ip4/192.168.1.61/tcp/6601/sessions'
        ,reg_addr_sessions("/ip4/192.168.1.61/tcp/6601")
    ),
    ok.

reg_addr_sessions_2_test() ->
    ?assertEqual(
        true
        ,reg_addr_sessions("/ip4/192.168.1.61/tcp/6601", self())
    ),
    reg_addr_sessions("/ip4/192.168.1.61/tcp/6601") ! test,
    receive M -> ?assertEqual(M, test) end,
    ?assertEqual(
        true
        ,unreg_addr_sessions("/ip4/192.168.1.61/tcp/6601")
    ),
    ok.

reg_addr_stream_1_test() ->
    ?assertEqual(
        '/ip4/192.168.1.61/tcp/6601/stream'
        ,reg_addr_stream("/ip4/192.168.1.61/tcp/6601")
    ),
    ok.

reg_addr_stream_2_test() ->
    ?assertEqual(
        true
        ,reg_addr_stream("/ip4/192.168.1.61/tcp/6601", self())
    ),
    reg_addr_stream("/ip4/192.168.1.61/tcp/6601") ! test,
    receive M -> ?assertEqual(M, test) end,
    erlang:spawn(fun() ->
        ?assertEqual(
            true
            ,reg_addr_stream("/ip4/192.168.1.61/tcp/6601", self())
        )
    end),
    receive M1 -> ?assertEqual(M1, stop) end,
    ok.

-endif.
