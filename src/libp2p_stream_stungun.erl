-module(libp2p_stream_stungun).

-behavior(libp2p_framed_stream).

-export([server/4, init/3, handle_data/3]).

server(Connection, "/dial/"++STUNTxnID, TID, _) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    libp2p_framed_stream:server(?MODULE, Connection, [TID, RemoteAddr, dial, list_to_integer(STUNTxnID)]);
server(Connection, "/reply/"++STUNTxnID, TID, _) ->
    libp2p_framed_stream:server(?MODULE, Connection, [TID, reply, list_to_integer(STUNTxnID)]).


init(server, _Connection, [TID, ObservedAddr, dial, STUNTxnID]) ->
    Sup = libp2p_swarm_sup:sup(TID),
    %% TODO we need to make sure we don't dial back on the same session the peer dialed us on, I guess?
    {ok, C} = libp2p_swarm:dial(Sup, ObservedAddr, lists:flatten(io_lib:format("stungun/1.0.0/reply/~b", [STUNTxnID])), [{unique, true}], 5000),
    libp2p_connection:close(C),
    {stop, normal};
init(server, Connection, [TID, reply, STUNTxnID]) ->
    Sup = libp2p_swarm_sup:sup(TID),
    Server = libp2p_swarm_sup:server(Sup),
    {LocalAddr, _} = libp2p_connection:addr_info(Connection),
    libp2p_swarm_server:stungun_response(Server, LocalAddr, STUNTxnID),
    {stop, normal}.

handle_data(server, _,  _) ->
    {stop, normal, undefined}.
