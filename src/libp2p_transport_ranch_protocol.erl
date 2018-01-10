-module(libp2p_transport_ranch_protocol).

-behaviour(ranch_protocol).

-export([start_link/4]).

start_link(Ref, Socket, _, {Transport, TID}) ->
    Connection = Transport:new_connection(Socket),
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    case libp2p_config:lookup_session(TID, RemoteAddr) of
        {ok, _Pid} -> error({already_connected, RemoteAddr});
        false ->
            Handlers = [{Key, Handler} || {Key, {Handler, _}}
                                              <- libp2p_config:lookup_connection_handlers(TID)],
            {ok, Pid} = libp2p_multistream_server:start_link(Ref, Connection, Handlers, TID),
            libp2p_config:insert_session(TID, RemoteAddr, Pid),
            {ok, Pid}
    end.
