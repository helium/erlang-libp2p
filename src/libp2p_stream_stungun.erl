-module(libp2p_stream_stungun).

-behavior(libp2p_framed_stream).

-export([server/4, init/3, handle_data/3]).

-define(OK, <<0:8/integer-unsigned>>).
-define(PORT_RESTRICTED_NAT, <<1:8/integer-unsigned>>).
-define(SYMMETRIC_NAT, <<2:8/integer-unsigned>>).

server(Connection, "/dial/"++STUNTxnID, TID, _) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    libp2p_framed_stream:server(?MODULE, Connection, [TID, RemoteAddr, dial, list_to_integer(STUNTxnID)]);
server(Connection, "/reply/"++STUNTxnID, TID, _) ->
    libp2p_framed_stream:server(?MODULE, Connection, [TID, reply, list_to_integer(STUNTxnID)]).


init(client, _Connection, [Parent]) ->
    {ok, Parent};
init(server, _Connection, [TID, ObservedAddr, dial, STUNTxnID]) ->
    Sup = libp2p_swarm_sup:sup(TID),
    %% first, try with the unique dial option, so we can check if the peer has Full Cone or Restricted Cone NAT
    case libp2p_swarm:dial(Sup, ObservedAddr, lists:flatten(io_lib:format("stungun/1.0.0/reply/~b", [STUNTxnID])), [{unique, true}], 5000) of
        {ok, C} ->
            libp2p_connection:close(C),
            %% ok they have full-cone or restricted cone NAT
            %% without trying from an unrelated IP we can't distinguish
            {stop, normal, ?OK};
        {error, _} ->
            case libp2p_swarm:dial(Sup, ObservedAddr, lists:flatten(io_lib:format("stungun/1.0.0/reply/~b", [STUNTxnID])), [], 5000) of
                {ok, C2} ->
                    %% ok they have port restricted cone NAT
                    libp2p_connection:close(C2),
                    {stop, normal, ?PORT_RESTRICTED_NAT};
                {error, _} ->
                    %% reply here to tell the peer we can't dial back at all
                    %% and they're behind symmetric NAT
                    {stop, normal, ?SYMMETRIC_NAT}
            end
    end;
init(server, Connection, [TID, reply, STUNTxnID]) ->
    Sup = libp2p_swarm_sup:sup(TID),
    Server = libp2p_swarm_sup:server(Sup),
    {LocalAddr, _} = libp2p_connection:addr_info(Connection),
    libp2p_swarm_server:stungun_response(Server, LocalAddr, STUNTxnID),
    {stop, normal}.

handle_data(client, ?OK, Parent) ->
    lager:info("Full cone or restricted cone nat detected"),
    {stop, normal, Parent};
handle_data(client, ?PORT_RESTRICTED_NAT, Parent) ->
    lager:info("Port restricted cone nat detected"),
    {stop, normal, Parent};
handle_data(client, ?SYMMETRIC_NAT, Parent) ->
    lager:info("Symmetric nat detected, RIP"),
    {stop, normal, Parent};
handle_data(server, _,  _) ->
    {stop, normal, undefined}.
