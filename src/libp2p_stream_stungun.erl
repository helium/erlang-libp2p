-module(libp2p_stream_stungun).

-behavior(libp2p_framed_stream).

-type txn_id() :: non_neg_integer().
-export_type([txn_id/0]).

%% API
-export([mk_stun_txn/0, mk_stun_txn/1, dial/5]).
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

-spec mk_stun_txn(pos_integer()) -> {string(), txn_id()}.
mk_stun_txn(Port) ->
    <<TxnID:96/integer-unsigned-little>> = crypto:strong_rand_bytes(12),
    PeerPath = lists:flatten(io_lib:format("stungun/1.0.0/dial/~b/~b", [Port, TxnID])),
    {PeerPath, TxnID}.

-spec dial(ets:tab(), string(), string(), txn_id(), pid()) -> {ok, pid()} | {error, term()}.
dial(TID, PeerAddr, PeerPath, TxnID, Handler) ->
    libp2p_swarm:dial_framed_stream(TID, PeerAddr, PeerPath, ?MODULE, [TxnID, Handler, TID]).

%%
%% libp2p_framed_stream
%%

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(client, _Connection, [TxnID, Handler, _TID]) ->
    {ok, #client_state{txn_id=TxnID, handler=Handler}};
init(server, Connection, ["/dial/"++Path, _, TID]) ->
    {_, ObservedAddr0} = libp2p_connection:addr_info(Connection),
    [{"ip4", IP}, {"tcp", PortStr0}] = multiaddr:protocols(ObservedAddr0),
    {ObservedAddr, PortStr} = case string:tokens(Path, "/") of
                                  [TxnID] ->
                                      {ObservedAddr0, PortStr0};
                                  [Port, TxnID] ->
                                      {"/ip4/"++IP++"/tcp/"++Port, Port}
                              end,
    {ok, SessionPid} = libp2p_connection:session(Connection),
    %% first, try with the unique dial option, so we can check if the
    %% peer has Full Cone or Restricted Cone NAT
    ReplyPath = reply_path(TxnID),
    lager:debug("stungun attempting dial back with unique session and port to ~p with txnid ~p", [ObservedAddr, TxnID]),
    %case libp2p_swarm:dial(TID, ObservedAddr, ReplyPath,
                           %[{unique_session, true}, {unique_port, true}], 5000) of
    case gen_tcp:connect(IP, list_to_integer(PortStr), [binary, {active, false}], 5000) of
        {ok, C} ->
            lager:debug("successfully dialed ~p using unique session/port", [ObservedAddr]),
            %libp2p_connection:close(C),
            gen_tcp:close(C),
            %% ok they have full-cone or restricted cone NAT without
            %% trying from an unrelated IP we can't distinguish Find
            %% an entry in the peerbook for a peer not connected to
            %% the target that we can use to distinguish
            case find_verifier(TID, libp2p_swarm:pubkey_bin(TID), find_p2p_addr(TID, SessionPid)) of
                {ok, VerifierAddr} ->
                    lager:debug("selected verifier to dial ~p for ~p", [VerifierAddr, ObservedAddr]),
                    VerifyPath = "stungun/1.0.0/verify/"++TxnID++ObservedAddr,
                    case libp2p_swarm:dial(TID, VerifierAddr, VerifyPath, [], 5000) of
                        {ok, VC} ->
                            %% TODO we need to check we're dialing who we think we're dialing here
                            %% in case we hit a different peer
                            lager:debug("verifier dial suceeded for ~p", [ObservedAddr]),
                            %% Read the response
                            case libp2p_framed_stream:recv(VC, 5000) of
                                {ok, ?OK} ->
                                    lager:debug("verifier dial reported ok"),
                                    %% Full cone or no restrictions on dialing back
                                    {stop, normal, ?OK};
                                {ok, ?FAILED} ->
                                    lager:debug("verifier dial reported failure for ~p", [ObservedAddr]),
                                    %% Restricted cone
                                    {stop, normal, ?RESTRICTED_NAT};
                                {error, Reason} ->
                                    lager:debug("verifier dial failed to respond for ~p : ~p", [ObservedAddr, Reason]),
                                    %% Could not determine
                                    {stop, normal, ?FAILED}
                            end;
                        {error, Reason} ->
                            lager:debug("verifier dial failed for ~p : ~p", [ObservedAddr, Reason]),
                            {stop, normal, ?FAILED}
                    end;
                {error, not_found} ->
                    lager:debug("no verifiers available for ~p", [ObservedAddr]),
                    {stop, normal, ?FAILED}
            end;
        {error, Reason} ->
            lager:debug("unique session/port dial failed: ~p, trying simple dial back", [Reason]),
            case libp2p_swarm:dial(TID, ObservedAddr, ReplyPath, [{unique_session, true}], 5000) of
                {ok, C2} ->
                    lager:debug("detected port restricted NAT for ~p", [ObservedAddr]),
                    %% ok they have port restricted cone NAT
                    libp2p_connection:close(C2),
                    {stop, normal, ?PORT_RESTRICTED_NAT};
                {error, Reason2} ->
                    lager:debug("detected port symmetric NAT for ~p ~p", [ObservedAddr, Reason2]),
                    %% reply here to tell the peer we can't dial back at all
                    %% and they're behind symmetric NAT
                    {stop, normal, ?SYMMETRIC_NAT}
            end
    end;
init(server, Connection, ["/reply/"++TxnID, Handler, TID]) ->
    lager:debug("got reply confirmation for  ~p", [TxnID]),
    {ok, SessionPid} = libp2p_connection:session(Connection),
    case libp2p_config:lookup_session_direction(TID, SessionPid) of
        inbound ->
            {LocalAddr, _} = libp2p_connection:addr_info(Connection),
            Handler ! {stungun_reply, list_to_integer(TxnID), LocalAddr};
        _ ->
            lager:info("ignoring IP address confirmation on outbound session"),
            ok
    end,
    {stop, normal};
init(server, _Connection, ["/verify/"++Info, _Handler, TID]) ->
    {TxnID, TargetAddr} = string:take(Info, "/", true),
    lager:debug("got verify request for ~p", [TargetAddr]),
    ReplyPath = reply_path(TxnID),
    case libp2p_swarm:dial(TID, TargetAddr, ReplyPath, [no_relay], 5000) of
        {error, eaddrnotavail} ->
            %% this is a local failure
            {stop, normal};
        {ok, C} ->
            lager:debug("verify dial succeeded for ~p", [TargetAddr]),
            libp2p_connection:close(C),
            {stop, normal, ?OK};
        {error, Reason} ->
            lager:debug("verify dial failed for ~p : ~p", [TargetAddr, Reason]),
            {stop, normal, ?FAILED}
    end.

handle_data(client, Code, State=#client_state{txn_id=TxnID, handler=Handler}) ->
    lager:debug("Got code ~p for txnid ~p", [Code, TxnID]),
    {NatType, _Info} = to_nat_type(Code),
    Handler ! {stungun_nat, TxnID, NatType},
    {stop, normal, State};

handle_data(server, _,  _) ->
    {stop, normal, undefined}.


%%
%% Internal
%%

%% @private Find the p2p address for the given multiaddress
-spec find_p2p_addr(ets:tab(), pid()) -> {ok, string()} | {error, not_found}.
find_p2p_addr(TID, SessionPid) ->
    find_p2p_addr(TID, SessionPid, 5).

find_p2p_addr(TID, SessionPid, Retries) ->
    SessionAddrs = libp2p_config:lookup_session_addrs(TID, SessionPid),
    case lists:filter(fun(A) ->
                              case multiaddr:protocols(A) of
                                  %% Ensur we only take simple p2p
                                  %% addresses and not relayed
                                  %% addresses.
                                  [{"p2p", _}] -> true;
                                  _ -> false
                              end
                      end, SessionAddrs) of
        [P2PAddr] -> {ok, P2PAddr};
        _ when Retries > 0 ->
            lager:debug("failed to find p2p address for ~p, waiting for identify to complete"),
            timer:sleep(1000),
            find_p2p_addr(TID, SessionPid, Retries - 1);
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
    lager:debug("finding peer for ~p not connected to ~p", [TargetAddr, libp2p_crypto:pubkey_bin_to_p2p(FromAddr)]),
    PeerBook = libp2p_swarm:peerbook(TID),
    {ok, FromEntry} = libp2p_peerbook:get(PeerBook, FromAddr),
    TargetCryptoAddr = libp2p_crypto:p2p_to_pubkey_bin(TargetAddr),
    %% Gets the peers connected to the given FromAddr
    FromConnected = libp2p_peer:connected_peers(FromEntry),
    lager:debug("Our peers: ~p", [[libp2p_crypto:pubkey_bin_to_p2p(F) || F <- FromConnected]]),
    case lists:filter(fun(P) ->
                              %% Get the entry for the connected peer
                              {ok, Peer} = libp2p_peerbook:get(PeerBook, P),
                              Res = not (lists:member(TargetCryptoAddr,
                                                      libp2p_peer:connected_peers(Peer))
                                         orelse libp2p_peer:pubkey_bin(Peer) == TargetCryptoAddr),
                              lager:debug("peer ~p connected to ~p ? ~p",
                                          [libp2p_crypto:pubkey_bin_to_p2p(libp2p_peer:pubkey_bin(Peer)),
                                           [libp2p_crypto:pubkey_bin_to_p2p(F)
                                            || F <- libp2p_peer:connected_peers(Peer)],
                                           Res]),
                              Res
                      end, FromConnected) of
        [] -> {error, not_found};
        Candidates ->
            Candidate = lists:nth(rand:uniform(length(Candidates)), Candidates),
            {ok, libp2p_crypto:pubkey_bin_to_p2p(Candidate)}
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
