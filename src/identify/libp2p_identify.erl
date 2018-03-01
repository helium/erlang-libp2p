-module(libp2p_identify).

-include("pb/libp2p_identify_pb.hrl").

-opaque identify() :: #libp2p_identify_pb{}.

-export_type([identify/0]).
-export([identify/1, spawn_identify/3, new/4, new/5, encode/1, decode/1,
         address/1, protocol_version/1, listen_addrs/1, observed_maddr/1, observed_addr/1,
         protocols/1, agent_version/1]).

-define(VERSION, "identify/1.0.0").

-spec identify(pid()) -> {ok, string(), identify()} | {error, term()}.
identify(Session) ->
    case libp2p_session:start_client_stream(?VERSION, Session) of
        {error, Error} -> {error, Error};
        {ok, Stream} ->
            Result = case libp2p_framed_stream:recv(Stream) of
                         {error, Error} -> {error, Error};
                         {ok, Bin} ->
                             {_, RemoteAddr} = libp2p_session:addr_info(Session),
                             {ok, RemoteAddr, decode(Bin)}
                     end,
            libp2p_connection:close(Stream),
            Result
    end.


-spec spawn_identify(ets:tab(), pid(), any()) -> pid().
spawn_identify(TID, Session, UserData) ->
    spawn(fun() ->
                  Server = libp2p_swarm_sup:server(TID),
                  Server ! {identify, identify(Session), UserData}
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

-spec new(libp2p_crypto:address(), [multiaddr:multiaddr()], multiaddr:multiaddr(), [string()], string()) -> libp2p_identify_pb:libp2p_identify_pb().
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
