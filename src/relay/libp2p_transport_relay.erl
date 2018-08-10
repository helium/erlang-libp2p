-module(libp2p_transport_relay).

-behavior(libp2p_transport).

-export([
    start_link/1
    ,start_listener/2
    ,match_addr/1
    ,priority/0
    ,connect/5
    ,reg_addr/1
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

-spec priority() -> integer().
priority() -> 1.

-spec connect(pid(), string(), libp2p_swarm:connect_opts()
              ,pos_integer(), ets:tab()) -> {ok, pid()}
                                            | {ok, pid(), any()}
                                            | {error, term()}.
connect(Pid, MAddr, Options, Timeout, TID) ->
    Swarm = libp2p_swarm:swarm(TID),
    ListenAddresses = libp2p_swarm:listen_addrs(Swarm),
    case has_p2p_circuit(ListenAddresses) of
        false ->
            connect_relay(Pid, MAddr, Options, Timeout, TID);
        true ->
            connect_proxy(Pid, MAddr, Options, Timeout, TID)
    end.

-spec reg_addr(string()) -> atom().
reg_addr(Address) ->
    erlang:list_to_atom(Address ++ "/sessions").

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec connect_relay(pid(), string(), libp2p_swarm:connect_opts()
                    ,pos_integer(), ets:tab()) -> {ok, pid()}
                                                  | {ok, pid(), any()}
                                                  | {error, term()}.
connect_relay(_Pid, MAddr, Options, Timeout, TID) ->
    {ok, {RAddress, AAddress}} = libp2p_relay:p2p_circuit(MAddr),
    true = erlang:register(?MODULE:reg_addr(AAddress), self()),
    lager:info("init relay with ~p", [[MAddr, RAddress, AAddress]]),
    case libp2p_transport:connect_to(RAddress, Options, Timeout, TID) of
        {error, _Reason}=Error ->
            Error;
        {ok, SessionPid} ->
            Swarm = libp2p_swarm:swarm(TID),
            {ok, _} = libp2p_relay:dial_framed_stream(
                Swarm
                ,RAddress
                ,[{type, {bridge_br, MAddr}}]
            ),
            receive
                {sessions, [SessionPid2|_]=Sessions} ->
                    lager:info("using sessions: ~p instead of ~p", [Sessions, SessionPid]),
                    true  = erlang:unregister(?MODULE:reg_addr(AAddress)),
                    {ok, SessionPid2};
                _Error ->
                    lager:error("no relay sessions ~p", [_Error]),
                    {error, no_relay_session}
            after 8000 ->
                {error, timeout_relay_session}
            end
    end.

-spec connect_proxy(pid(), string(), libp2p_swarm:connect_opts()
                    ,pos_integer(), ets:tab()) -> {ok, pid()}
                                                  | {ok, pid(), any()}
                                                  | {error, term()}.
connect_proxy(_Pid, MAddr, Options, Timeout, TID) ->
    {ok, {RAddress, AAddress}} = libp2p_relay:p2p_circuit(MAddr),
    true = erlang:register(?MODULE:reg_addr(AAddress), self()),
    lager:info("init proxy with ~p", [[MAddr, RAddress, AAddress]]),
    case libp2p_transport:connect_to(RAddress, Options, Timeout, TID) of
        {error, _Reason}=Error ->
            Error;
        {ok, SessionPid} ->
            {ok, SessionPid, {proxy, libp2p_proxy:version(), AAddress}}
    end.

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


-spec has_p2p_circuit(list()) -> boolean().
has_p2p_circuit(Addresses) ->
    lists:foldl(
        fun(_, true) ->
            true;
        (Address, _) ->
            libp2p_relay:is_p2p_circuit(Address)
        end
        ,false
        ,Addresses
    ).
