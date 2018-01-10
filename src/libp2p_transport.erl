-module(libp2p_transport).

-type connection_handler() :: {atom(), atom()}.

-export_type([connection_handler/0]).
-export([for_addr/1]).

-spec for_addr(multiaddr:multiaddr() | string()) -> {ok, atom(), {string(), string()}} | {error, term()}.
for_addr(Addr) when is_binary(Addr) ->
    for_addr(multiaddr:to_string(Addr), multiaddr:protocols(Addr));
for_addr(Addr) when is_list(Addr) ->
    for_addr(Addr, multiaddr:protocols(multiaddr:new(Addr))).

-spec for_addr(string(), [multiaddr:protocol()]) -> {ok, atom(), {string(), string()}} | {error, term()}.
for_addr(_Addr, [A={_, _}, B={"tcp", _} | Rest]) ->
    {ok, libp2p_transport_tcp, {multiaddr:to_string([A, B]), multiaddr:to_string(Rest)}};
for_addr(Addr, _Protocols) ->
    {error, {unsupported_address, Addr}}.
