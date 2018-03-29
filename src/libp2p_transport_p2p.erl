-module(libp2p_transport_p2p).

-behavior(gen_server).
-behavior(libp2p_transport).

% gen_server
-export([start_link/1, init/1, handle_call/3, handle_cast/2]).

% libp2p_transport
-export([start_listener/2, connect/4, match_addr/1]).


-record(state,
       { tid :: ets:tab()
       }).

%% libp2p_transport
%%

-spec start_listener(pid(), string()) -> {error, unsupported}.
start_listener(_Pid, _Addr) ->
    {error, unsupported}.

-spec connect(pid(), string(), [libp2p_swarm:connect_opt()], pos_integer()) -> {ok, libp2p_session:pid()} | {error, term()}.
connect(Pid, MAddr, Options, Timeout) ->
    gen_server:call(Pid, {connect, MAddr, Options, Timeout}, infinity).

-spec match_addr(string()) -> {ok, string()} | false.
match_addr(Addr) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(multiaddr:new(Addr))).

match_protocols([A={"p2p", _} | _]) ->
    {ok, multiaddr:to_string([A])};
match_protocols(_) ->
    false.


%% gen_server
%%

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

init([TID]) ->
    erlang:process_flag(trap_exit, true),
    {ok, #state{tid=TID}}.

%% libp2p_transport
%
handle_call({connect, MAddr, DialOptions, Timeout}, _From, State=#state{tid=TID}) ->
    {reply, connect_to(MAddr, DialOptions, Timeout, TID), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p~n", [Msg]),
    {reply, ok, State}.


handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p~n", [Msg]),
    {noreply, State}.

%% Internal: Connect
%%

-spec connect_to(string(), [libp2p_swarm:connect_opt()], pos_integer(), ets:tab())
                -> {ok, libp2p_session:pid()} | {error, term()}.
connect_to(MAddr, UserOptions, Timeout, TID) ->
    case p2p_addr(MAddr) of
        {ok, Addr} ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(TID), Addr) of
                {ok, PeerInfo} ->
                    case connect_to_listen_addr(libp2p_peer:listen_addrs(PeerInfo), UserOptions, Timeout, TID) of
                        {ok, SessionPid}-> {ok, SessionPid};
                        {error, Error} -> {error, Error}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

-spec connect_to_listen_addr([string()], [libp2p_swarm:connect_opt()], pos_integer(), ets:tab())
                            -> {ok, libp2p_session:pid()} | {error, term()}.
connect_to_listen_addr([], _UserOptions, _Timeout, _TID) ->
    {error, no_listen_addr};
connect_to_listen_addr([ListenAddr | Tail], UserOptions, Timeout, TID) ->
    case libp2p_transport:connect_to(ListenAddr, UserOptions, Timeout, TID) of
        {_, _, SessionPid} ->
            {ok, SessionPid};
        {error, Error} ->
            case Tail of
                [] -> {error, Error};
                Remaining -> connect_to_listen_addr(Remaining, UserOptions, Timeout, TID)
            end
    end.

-spec p2p_addr(string()) -> {ok, libp2p_crypto:address()} | {error, term()}.
p2p_addr(MAddr) ->
    p2p_addr(MAddr, multiaddr:protocols(multiaddr:new(MAddr))).

p2p_addr(MAddr, [{"p2p", Addr}]) ->
    try
        {ok, libp2p_crypto:b58_to_address(Addr)}
    catch
        _What:Why ->
            lager:warning("Invalid p2p address ~p: ~p", [MAddr, Why]),
            {error, {invalid_address, MAddr}}
    end;
p2p_addr(MAddr, _Protocols) ->
    {error, {unsupported_address, MAddr}}.
