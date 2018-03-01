-module(libp2p_stream_identify).

-behavior(libp2p_framed_stream).

-export([server/4, init/3, handle_data/3]).

server(Connection, _Path, TID, _) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    libp2p_framed_stream:server(?MODULE, Connection, [TID, RemoteAddr]).

init(server, _Connection, [TID, ObservedAddr]) ->
    Sup = libp2p_swarm_sup:sup(TID),
    ListenAddrs = libp2p_swarm:listen_addrs(Sup),
    Protocols = [Key || {Key, _} <- libp2p_swarm:stream_handlers(Sup)],
    Identify = libp2p_identify:new(ListenAddrs, ObservedAddr, Protocols),
    {stop, normal, libp2p_identify_pb:encode_msg(Identify)}.

handle_data(server, _,  _) ->
    {stop, normal, undefined}.
