-module(libp2p_transport_ranch_protocol).

-behaviour(ranch_protocol).

-export([start_link/4]).

start_link(Ref, Socket, _, {Transport, TID}) ->
    Connection = Transport:new_connection(Socket),
    libp2p_transport:start_server_session(Ref, TID, Connection).
