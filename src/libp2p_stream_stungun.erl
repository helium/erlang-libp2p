-module(libp2p_stream_stungun).

-behavior(libp2p_framed_stream).

-export([start_client/3, start_client/5, init/3, handle_data/3, handle_info/3]).

-define(OK, <<0:8/integer-unsigned>>).
-define(PORT_RESTRICTED_NAT, <<1:8/integer-unsigned>>).
-define(SYMMETRIC_NAT, <<2:8/integer-unsigned>>).

-record(client_state, {
          txn_id :: binary(),
          handler :: pid(),
          timeout :: reference()
         }).

-define(STUN_TIMEOUT, 500).

start_client(TxnID, Swarm, PeerAddr) ->
    start_client(TxnID, Swarm, PeerAddr, self(), ?STUN_TIMEOUT).

start_client(TxnID, Swarm, PeerAddr, Handler, Timeout) ->
    PeerPath = lists:flatten(io_lib:format("stungun/1.0.0/dial/~b", [TxnID])),
    case libp2p_swarm:dial(Swarm, PeerAddr, PeerPath) of
        {ok, Connection} ->
            libp2p_framed_stream:client(?MODULE, Connection, [TxnID, Handler, Timeout]);
        {error, Error} -> {error, Error}
    end.

init(client, _Connection, [TxnID, Handler, Timeout]) ->
    Ref = erlang:send_after(Timeout, self(), timeout),
    {ok, #client_state{txn_id=TxnID, handler=Handler, timeout=Ref}};
init(server, Connection, ["/dial/"++TxnID, _, Swarm]) ->
    {_, ObservedAddr} = libp2p_connection:addr_info(Connection),
    %% first, try with the unique dial option, so we can check if the peer has Full Cone or Restricted Cone NAT
    ReplyPath = lists:flatten(io_lib:format("stungun/1.0.0/reply/~b", [list_to_integer(TxnID)])),
    case libp2p_swarm:dial(Swarm, ObservedAddr, ReplyPath, [{unique_session, true}, {unique_port, true}], 5000) of
        {ok, C} ->
            libp2p_connection:close(C),
            %% ok they have full-cone or restricted cone NAT
            %% without trying from an unrelated IP we can't distinguish
            {stop, normal, ?OK};
        {error, _} ->
            case libp2p_swarm:dial(Swarm, ObservedAddr, ReplyPath, [{unique_session, true}], 5000) of
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
init(server, Connection, ["/reply/"++TxnID, Handler, _Swarm]) ->
    {LocalAddr, _} = libp2p_connection:addr_info(Connection),
    Handler ! {stungun_reply, list_to_integer(TxnID), LocalAddr},
    {stop, normal}.

handle_data(client, ?OK, State=#client_state{timeout=Ref}) ->
    erlang:cancel_timer(Ref),
    lager:info("Full cone or restricted cone nat detected"),
    {stop, normal, State};
handle_data(client, ?PORT_RESTRICTED_NAT, State=#client_state{timeout=Ref}) ->
    erlang:cancel_timer(Ref),
    lager:info("Port restricted cone nat detected"),
    {stop, normal, State};
handle_data(client, ?SYMMETRIC_NAT, State=#client_state{timeout=Ref}) ->
    erlang:cancel_timer(Ref),
    lager:info("Symmetric nat detected, RIP"),
    {stop, normal, State};
handle_data(server, _,  _) ->
    {stop, normal, undefined}.

handle_info(client, timeout, State=#client_state{handler=Handler, txn_id=TxnID}) ->
    Handler ! {stungun_timeout, TxnID},
    {stop, normal, State}.
