-module(libp2p_identify).

-include("pb/libp2p_identify_pb.hrl").

-opaque identify() :: #libp2p_identify_pb{}.

-export_type([identify/0]).
-export([spawn_identify/3, new/4, new/5, encode/1, decode/1,
         address/1, protocol_version/1, listen_addrs/1, observed_maddr/1, observed_addr/1,
         protocols/1, agent_version/1]).

-define(VERSION, "identify/1.0.0").

-spec spawn_identify(Session::pid(), Handler::pid(), UserData::any()) -> pid().
spawn_identify(Session, Handler, HandlerArgs) ->
    spawn(fun() ->
                  libp2p_session:dial_framed_stream(?VERSION, Session,
                                                    libp2p_stream_identify, [Session, Handler, HandlerArgs])
          end).

-spec new(libp2p_crypto:address(), [string()], string(), [string()])
         -> libp2p_identify_pb:libp2p_identify_pb().
new(Address, ListenAddrs, ObservedAddr, Protocols) ->
    Version = case lists:keyfind(libp2p, 1, application:loaded_applications()) of
                  {_, _, V} -> V;
                  false -> "unknown"
              end,
    AgentVersion = application:get_env(libp2p, agent_version,
                                       list_to_binary(["erlang-libp2p/", Version])),
    new(Address,
        lists:map(fun multiaddr:new/1, ListenAddrs),
        multiaddr:new(ObservedAddr),
        Protocols, AgentVersion).

-spec new(libp2p_crypto:address(), [multiaddr:multiaddr()], multiaddr:multiaddr(), [string()], string()) -> identify().
new(Address, ListenAddrs, ObservedAddr, Protocols, AgentVersion) ->
    #libp2p_identify_pb{publicKey=Address,
                        protocol_version=?VERSION,
                        listen_addrs=ListenAddrs,
                        observed_addr=ObservedAddr,
                        protocols=Protocols,
                        agent_version=AgentVersion
                       }.

-spec protocol_version(identify()) -> string().
protocol_version(#libp2p_identify_pb{protocol_version=Version}) ->
     Version.


-spec address(identify()) -> libp2p_crypto:address().
address(#libp2p_identify_pb{publicKey=Address}) ->
    Address.

-spec listen_addrs(identify()) -> [multiaddr:multiaddr()].
listen_addrs(#libp2p_identify_pb{listen_addrs=ListenAddrs}) ->
    ListenAddrs.

-spec observed_addr(identify()) -> string().
observed_addr(Identify=#libp2p_identify_pb{}) ->
    multiaddr:to_string(observed_maddr(Identify)).

observed_maddr(#libp2p_identify_pb{observed_addr=ObservedAddr}) ->
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
