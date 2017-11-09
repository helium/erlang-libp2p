-module(libp2p_transport_tcp_protocol).

-behaviour(ranch_protocol).

-export([start_link/4]).

start_link(Ref, Socket, _Transport, Opts) ->
    {protocol_module, Module} = lists:keyfind(protocol_module, 1, Opts),
    Module:start_link(Ref, connection:new(Socket)).
