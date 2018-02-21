-module(libp2p_identify).

-include("libp2p_identify_pb.hrl").

-opaque identify() :: #libp2p_identify_pb{}.

-export_type([identify/0]).
-export([identify/2, new/3, new/4, encode/1, decode/1,
         protocol_version/1, listen_addrs/1, observed_addr/1, protocols/1, agent_version/1]).

-define(VERSION, "identify/1.0.0").

-spec identify(pid(), string()) -> {ok, identify()} | {error, term()}.
identify(Swarm, Addr) ->
    case libp2p_swarm:dial(Swarm, Addr, ?VERSION) of
        {error, Error} -> {error, Error};
        {ok, Stream} ->
            Result = case libp2p_framed_stream:recv(Stream) of
                         {error, Error} -> {error, Error};
                         {ok, Bin} -> {ok, decode(Bin)}
                     end,
            libp2p_connection:close(Stream),
            Result
    end.

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

-spec protocol_version(identify()) -> string().
protocol_version(#libp2p_identify_pb{protocol_version=Version}) ->
     Version.

-spec listen_addrs(identify()) -> [multiaddr:multiaddr()].
listen_addrs(#libp2p_identify_pb{listen_addrs=ListenAddrs}) ->
    ListenAddrs.

-spec observed_addr(identify()) -> multiaddr:multiaddr().
observed_addr(#libp2p_identify_pb{observed_addr=ObservedAddr}) ->
    ObservedAddr.

-spec protocols(identify()) -> [string()].
protocols(#libp2p_identify_pb{protocols=Protocols}) ->
    Protocols.

-spec agent_version(identify()) -> string().
agent_version(#libp2p_identify_pb{agent_version=Version}) ->
    Version.

-spec encode(identify()) -> binary().
encode(Msg=#libp2p_identify_pb{}) ->
    libp2p_identify_pb:encode_msg(Msg).

-spec decode(binary()) -> identify().
decode(Bin) ->
    libp2p_identify_pb:decode_msg(Bin, libp2p_identify_pb).
