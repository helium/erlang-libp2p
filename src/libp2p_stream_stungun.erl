-module(libp2p_stream_stungun).

-behavior(libp2p_framed_stream).

-type txn_id() :: non_neg_integer().
-export_type([txn_id/0]).

%% API
-export([mk_stun_txn/0, dial/5]).
%% libp2p_framed_stream
-export([client/2, server/4, init/3, handle_data/3]).

-define(OK, <<0:8/integer-unsigned>>).
-define(RESTRICTED_NAT, <<1:8/integer-unsigned>>).
-define(PORT_RESTRICTED_NAT, <<2:8/integer-unsigned>>).
-define(SYMMETRIC_NAT, <<3:8/integer-unsigned>>).
-define(FAILED, <<4:8/integer-unsigned>>).

-record(client_state, {
          txn_id :: binary(),
          handler :: pid()
         }).

%%
%% API
%%

-spec mk_stun_txn() -> {string(), txn_id()}.
mk_stun_txn() ->
    <<TxnID:96/integer-unsigned-little>> = crypto:strong_rand_bytes(12),
    PeerPath = lists:flatten(io_lib:format("stungun/1.0.0/dial/~b", [TxnID])),
    {PeerPath, TxnID}.

-spec dial(ets:tab(), string(), string(), txn_id(), pid()) -> {ok, pid()} | {error, term()}.
dial(TID, PeerAddr, PeerPath, TxnID, Handler) ->
    libp2p_swarm:dial_framed_stream(TID, PeerAddr, PeerPath, ?MODULE, [TxnID, Handler]).

%%
%% libp2p_framed_stream
%%

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(client, _Connection, [TxnID, Handler]) ->
    {ok, #client_state{txn_id=TxnID, handler=Handler}};
init(server, Connection, ["/dial/"++TxnID, _, TID]) ->
    {_, ObservedAddr} = libp2p_connection:addr_info(Connection),
    %% first, try with the unique dial option, so we can check if the peer has Full Cone or Restricted Cone NAT
    ReplyPath = reply_path(TxnID),
    case libp2p_swarm:dial(TID, ObservedAddr, ReplyPath,
                           [{unique_session, true}, {unique_port, true}], 5000) of
        {ok, C} ->
            libp2p_connection:close(C),
            %% ok they have full-cone or restricted cone NAT without
            %% trying from an unrelated IP we can't distinguish Find
            %% an entry in the peerbook for a peer not connected to
            %% the target that we can use to distinguish
            {ok, VerifierAddr} = find_verifier(TID, libp2p_swarm:address(TID),
                                               find_p2p_addr(TID, ObservedAddr)),
            VerifyPath = "/verify/"++TxnID++ObservedAddr,
            case libp2p_swarm:dial(TID, VerifierAddr, VerifyPath, [], 5000) of
                {ok, VC} ->
                    %% Read the response
                    case libp2p_framed_stream:recv(VC, 5000) of
                        {ok, ?OK} ->
                            %% Full cone or no restrictions on dialing back
                            {stop, normal, ?OK};
                         {ok, ?FAILED} ->
                            %% Restricted cone
                            {stop, normal, ?RESTRICTED_NAT};
                        {error, _} ->
                            %% Could not determine
                            {stop, normal, ?FAILED}
                    end
            end;
        {error, _} ->
            case libp2p_swarm:dial(TID, ObservedAddr, ReplyPath, [{unique_session, true}], 5000) of
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
init(server, Connection, ["/reply/"++TxnID, Handler, _TID]) ->
    {LocalAddr, _} = libp2p_connection:addr_info(Connection),
    Handler ! {stungun_reply, list_to_integer(TxnID), LocalAddr},
    {stop, normal};
init(server, _Connection, ["/verify/"++Info, _Handler, TID]) ->
    {TxnID, TargetAddr} = string:take(Info, "/", true),
    ReplyPath = reply_path(TxnID),
    case libp2p_swarm:dial(TID, TargetAddr, ReplyPath, [], 5000) of
        {ok, C} ->
            libp2p_connection:close(C),
            {stop, normal, ?OK};
        {error, _} ->
            {stop, normal, ?FAILED}
    end.

handle_data(client, Code, State=#client_state{txn_id=TxnID, handler=Handler}) ->
    {NatType, _Info} = to_nat_type(Code),
    Handler ! {stungun_nat, TxnID, NatType},
    {stop, normal, State};

handle_data(server, _,  _) ->
    {stop, normal, undefined}.


%%
%% Internal
%%

%% @private Find the p2p address for the given multiaddress
-spec find_p2p_addr(ets:tab(), string()) -> {ok, string()} | {error, not_found}.
find_p2p_addr(TID, Addr) ->
    {ok, SessionPid} = libp2p_config:lookup_session(TID, Addr),
    SessionAddrs = libp2p_config:lookup_session_addrs(TID, SessionPid),
    case lists:filter(fun(A) ->
                              case multiaddr:protocols(multiaddr:new(A)) of
                                  %% Ensur we only take simple p2p
                                  %% addresses and not relayed
                                  %% addresses.
                                  [{"p2p", _}] -> true;
                                  _ -> false
                              end
                      end, SessionAddrs) of
        [P2PAddr] -> {ok, P2PAddr};
        _ -> {error, not_found}
    end.

%% @private Find a peer in the peerbook who is connected to the
%% given FromAddr but _not_ connected to the given TargetAddr
-spec find_verifier(ets:tab(), binary(), {error, not_found} | {ok, string()} | string())
                   -> {ok, string()} | {error, not_found}.
find_verifier(_TID, _, {error, not_found}) ->
    {error, not_found};
find_verifier(TID, FromAddr, {ok, TargetAddr}) ->
    find_verifier(TID, FromAddr, TargetAddr);
find_verifier(TID, FromAddr, TargetAddr) ->
    PeerBook = libp2p_swarm:peerbook(TID),
    {ok, FromEntry} = libp2p_peerbook:get(PeerBook, FromAddr),
    TargetCryptoAddr = libp2p_crypto:p2p_to_address(TargetAddr),
    %% Gets the peers connected to the given FromAddr
    FromConnected = libp2p_peer:connected_peers(FromEntry),
    case lists:filter(fun(P) ->
                              %% Get the entry for the connected peer
                              {ok, Peer} = libp2p_peerbook:get(PeerBook, P),
                              not lists:member(TargetCryptoAddr,
                                               libp2p_peer:connected_peers(Peer))
                      end, FromConnected) of
        [Candidate | _] -> {ok, libp2p_crypto:address_to_p2p(Candidate)};
        [] -> {error, not_found}
    end.




reply_path(TxnID) ->
    lists:flatten(io_lib:format("stungun/1.0.0/reply/~b", [list_to_integer(TxnID)])).

to_nat_type(?OK) ->
    {none, "Full cone nat detected"};
to_nat_type(?RESTRICTED_NAT) ->
    {restricted, "Restricted cone nat detected"};
to_nat_type(?PORT_RESTRICTED_NAT) ->
    {restricted, "Port restricted cone nat detected"};
to_nat_type(?SYMMETRIC_NAT) ->
    {symmetric, "Symmetric nat detected, RIP"};
to_nat_type(?FAILED) ->
    {unknown, "Unknown nat"}.
