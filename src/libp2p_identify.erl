-module(libp2p_identify).

-include("libp2p_identify_pb.hrl").

-opaque identify() :: #libp2p_identify_pb{}.

-export_type([identify/0]).
-export([new/3, new/4, encode/1, decode/1,
        protocol_version/1, listen_addrs/1, observed_addr/1, protocols/1, agent_version/1]).

-define(VERSION, "identify/1.0.0").

-spec new([string()], string(), [string()]) -> libp2p_identify_pb:libp2p_identify_pb().
new(ListenAddrs, ObservedAddr, Protocols) ->
    Version = case lists:keyfind(libp2p, 1, application:loaded_applications()) of
                  {_, _, V} -> V;
                  false -> "unknown"
              end,
    AgentVersion = application:get_env(libp2p, agent_version,
                                       list_to_binary(["erlang-libp2p/", Version])),
    new(lists:map(fun multiaddr:new/1, ListenAddrs),
        multiaddr:new(ObservedAddr),
        Protocols, AgentVersion).

-spec new([multiaddr:multiaddr()], multiaddr:multiaddr(), [string()], string()) -> libp2p_identify_pb:libp2p_identify_pb().
new(ListenAddrs, ObservedAddr, Protocols, AgentVersion) ->
    #libp2p_identify_pb{protocol_version=?VERSION,
                        listen_addrs=ListenAddrs,
                        observed_addr=ObservedAddr,
                        protocols=Protocols,
                        agent_version=AgentVersion
                       }.

protocol_version(#libp2p_identify_pb{protocol_version=Version}) ->
     Version.

listen_addrs(#libp2p_identify_pb{listen_addrs=ListenAddrs}) ->
    ListenAddrs.

observed_addr(#libp2p_identify_pb{observed_addr=ObservedAddr}) ->
    ObservedAddr.

protocols(#libp2p_identify_pb{protocols=Protocols}) ->
    Protocols.

agent_version(#libp2p_identify_pb{agent_version=Version}) ->
    Version.

-spec encode(identify()) -> binary().
encode(Msg=#libp2p_identify_pb{}) ->
    libp2p_identify_pb:encode_msg(Msg).

-spec decode(binary()) -> identify().
decode(Bin) ->
    libp2p_identify_pb:decode_msg(Bin, libp2p_identify_pb).
