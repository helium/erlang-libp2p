-module(libp2p_transport_relay).

-behavior(libp2p_transport).

-export([
    start_link/1
    ,start_listener/2
    ,match_addr/1
    ,connect/5
    ,reg/1
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
    {ok, {To, A}} = libp2p_relay:p2p_circuit(MAddr),
    true = erlang:register(?MODULE:reg(A), self()),
    % TODO: This should not be forced to tcp will have to find a fix for that
    case libp2p_transport_tcp:connect(Pid, To, Options, Timeout, TID) of
        {error, _Reason}=Error -> Error;
        {ok, _SessionPid} ->
            Swarm = libp2p_swarm:swarm(TID),
            {ok, _} = libp2p_relay:dial_framed_stream(
                Swarm
                ,To
                ,[{type, {bridge_br, MAddr}}]
            ),
            receive
                {sessions, [SessionPid|_]=Sessions} ->
                    lager:info("using sessions: ~p instead of ~p", [Sessions, _SessionPid]),
                    true  = erlang:unregister(?MODULE:reg(A)),
                    {ok, SessionPid};
                _Error ->
                    lager:error("no relay sessions ~p", [_Error]),
                    {error, no_relay_session}
            after 8000 ->
                {error, timeout_relay_session}
            end
    end.

-spec reg(string()) -> atom().
reg(Address) ->
    erlang:list_to_atom(Address ++ "/A").

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
