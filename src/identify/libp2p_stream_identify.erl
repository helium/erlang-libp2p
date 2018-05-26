-module(libp2p_stream_identify).

-behavior(libp2p_framed_stream).

-export([client/2, server/4, init/3, handle_data/3]).

-record(state,
       { handler:: pid(),
         handler_args :: any(),
         session :: pid()
       }).

client(Connection, Args=[_Session, _Handler, _HandlerArgs]) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, _Path, TID, _) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    libp2p_framed_stream:server(?MODULE, Connection, [TID, RemoteAddr]).

init(server, _Connection, [TID, ObservedAddr]) ->
    Sup = libp2p_swarm_sup:sup(TID),
    ListenAddrs = libp2p_swarm:listen_addrs(Sup),
    Protocols = [Key || {Key, _} <- libp2p_swarm:stream_handlers(Sup)],
    Addr = libp2p_swarm:address(TID),
    Identify = libp2p_identify:new(Addr, ListenAddrs, ObservedAddr, Protocols),
    {stop, normal, libp2p_identify:encode(Identify)};
init(client, _Connection, [Session, Handler, HandlerArgs]) ->
    {ok, #state{session=Session, handler=Handler, handler_args=HandlerArgs}}.


handle_data(client, Data, State=#state{handler=Handler, session=Session, handler_args=HandlerArgs}) ->
    Identify = libp2p_identify:decode(Data),
    Handler ! {identify, HandlerArgs, Session, Identify},
    {stop, normal, State}.
