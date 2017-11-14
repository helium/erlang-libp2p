-module(libp2p_transport_tcp_protocol).

-behaviour(ranch_protocol).

-export([start_link/4]).

start_link(Ref, Socket, _Transport, Opts) ->
    {protocol_module, Module} = lists:keyfind(protocol_module, 1, Opts),
    ProtocolOpts = case lists:keyfind(protocol_opts, 1, Opts) of
                       {protocol_opts, Value} -> Value;
                       false -> []
                   end,
    Module:start_link(Ref, libp2p_transport_tcp:new_connection(Socket), ProtocolOpts).
