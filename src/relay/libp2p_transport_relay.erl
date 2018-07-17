-module(libp2p_transport_relay).

-behavior(libp2p_transport).

-export([
    start_link/1
    ,start_listener/2
    ,match_addr/1
    ,connect/5
]).

%% ------------------------------------------------------------------
%% libp2p_transport
%% ------------------------------------------------------------------
-spec start_link(ets:tab()) -> ignore.
start_link(_TID) ->
    ignore.

-spec start_listener(pid(), string()) -> {error, unsupported}.
start_listener(_Pid, _Addr) ->
    {error, unsupported}.

-spec match_addr(string()) -> {ok, string()} | false.
match_addr(Addr) when is_list(Addr) ->
    match_protocols(multiaddr:protocols(multiaddr:new(Addr))).

-spec connect(pid(), string(), libp2p_swarm:connect_opts()
              ,pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
connect(Pid, MAddr, Options, Timeout, TID) ->
    % TODO: This should not be forced to tcp will have to find a fix for that
    case libp2p_transport_tcp:connect(Pid, MAddr, Options, Timeout, TID) of
        {error, _Reason}=Error -> Error;
        {ok, _SessionPid}=OK ->
            % TODO: create relay frame stream (B -> R) before doing anything else
            % then wait for A to connect to B
            OK
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec match_protocols(list()) -> {ok, string()} | false.
match_protocols(Protocols) ->
    match_protocols(Protocols, []).

-spec match_protocols(list(), list()) -> {ok, string()} | false.
match_protocols([], _Acc) ->
    false;
match_protocols([{"p2p-circuit", _} | _]=A, Acc) ->
    {ok, multiaddr:to_string(lists:reverse(Acc) ++ A)};
match_protocols([{_, _}=Head | Tail], Acc) ->
    match_protocols(Tail, [Head|Acc]).
