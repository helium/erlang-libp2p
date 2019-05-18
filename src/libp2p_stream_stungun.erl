-module(libp2p_stream_stungun).

-behavior(libp2p_stream).

-type txn_id() :: non_neg_integer().
-export_type([txn_id/0]).

%% API
-export([protocol_id/0, mk_stun_txn/0, dial/5]).
%% libp2p_stream
-export([init/2, handle_packet/4, handle_info/3]).

-define(OK, <<0:8/integer-unsigned>>).
-define(RESTRICTED_NAT, <<1:8/integer-unsigned>>).
-define(PORT_RESTRICTED_NAT, <<2:8/integer-unsigned>>).
-define(SYMMETRIC_NAT, <<3:8/integer-unsigned>>).
-define(FAILED, <<4:8/integer-unsigned>>).
-define(PACKET(P), libp2p_packet:encode_packet([u8], 1, P)).

-record(client_state, {
          txn_id :: binary(),
          handler :: pid()
         }).

-record(server_state, {
                       state :: dial_verify,
                       observed_addr :: string()
                      }).

%%
%% API
%%

protocol_id() ->
    <<"stungun/1.0.0">>.

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

init(client, #{ txn_id :=  TxnID, handler :=  Handler}) ->
    {ok, #client_state{txn_id=TxnID, handler=Handler},
    [{active, once},
     {packet_spec, [u8]}]};
init(server, #{ path := "/dial/"++TxnID, tid := TID }) ->
    SessionPid = libp2p_stream_transport:stream_muxer(),
    {_, ObservedAddr} = libp2p_stream_transport:stream_addr_info(),
    %% first, try with the unique dial option, so we can check if the
    %% peer has Full Cone or Restricted Cone NAT
    lager:debug("stungun attempting dial back with unique session and port to ~p", [ObservedAddr]),
    [{"ip4", IP}, {"tcp", PortStr}] = multiaddr:protocols(ObservedAddr),
    case gen_tcp:connect(IP, list_to_integer(PortStr), [binary, {active, false}], 5000) of
        {ok, C} ->
            lager:debug("successfully dialed ~p using unique session/port", [ObservedAddr]),
            gen_tcp:close(C),
            %% ok they have full-cone or restricted cone NAT without
            %% trying from an unrelated IP we can't distinguish Find
            %% an entry in the peerbook for a peer not connected to
            %% the target that we can use to distinguish
            case find_verifier(TID, libp2p_swarm:pubkey_bin(TID), find_p2p_addr(TID, SessionPid)) of
                {ok, VerifierAddr} ->
                    lager:debug("selected verifier to dial ~p for ~p", [VerifierAddr, ObservedAddr]),
                    VerifyPath = "stungun/1.0.0/verify/"++TxnID++ObservedAddr,
                    case libp2p_muxer:dial(SessionPid,
                                           #{ handlers => [{list_to_binary(VerifyPath),
                                                            {?MODULE, #{ txn_id => TxnID,
                                                                         handler => self()}}}]}) of
                        {ok, _} ->
                            {ok, #server_state{state=dial_verify, observed_addr=ObservedAddr},
                            [ {active, once},
                              {packet_spec, [u8]},
                              {timer, dial_verify_timeout, 5000}]};
                        {error, Reason} ->
                            lager:debug("verifier dial failed for ~p : ~p", [ObservedAddr, Reason]),
                            {stop, normal, undefined,
                             [{send, ?PACKET(?FAILED)}]}
                    end;
                {error, not_found} ->
                    lager:debug("no verifiers available for ~p", [ObservedAddr]),
                    {stop, normal, undefined,
                     [{send, ?PACKET(?FAILED)}]}
            end;
        {error, Reason} ->
            lager:debug("unique session/port dial failed: ~p, trying simple dial back", [Reason]),
            ReplyPath = reply_path(TxnID),
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
init(server, #{ path := "/reply/"++TxnID, handler := Handler}) ->
    {LocalAddr, _} = libp2p_stream_transport:stream_addr_info(),
    Handler ! {stungun_reply, list_to_integer(TxnID), LocalAddr},
    {stop, normal};
init(server, #{ path := "/verify/"++Info, handler := _Handler, tid := TID}) ->
    {TxnID, TargetAddr} = string:take(Info, "/", true),
    lager:debug("got verify request for ~p", [TargetAddr]),
    ReplyPath = reply_path(TxnID),
    case libp2p_swarm:dial(TID, TargetAddr, ReplyPath, [], 5000) of
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


handle_packet(client, _, Code, State=#client_state{txn_id=TxnID, handler=Handler}) ->
    {NatType, _Info} = to_nat_type(Code),
    Handler ! {stungun_nat, TxnID, NatType},
    {stop, normal, State};

handle_packet(server, _, _,  _) ->
    {stop, normal, undefined}.

%% Dial verify
handle_info(server, {stungun_nat, _, none}, State=#server_state{state=dial_verify}) ->
    lager:debug("verifier dial reported ok"),
    %% Full cone or no restrictions on dialing back
    {stop, normal, State,
     [{send, ?PACKET(?OK)}]};
handle_info(server, {stungun_nat, _, unknown}, State=#server_state{state=dial_verify}) ->
    lager:debug("verifier dial reported failure for ~p", [State#server_state.observed_addr]),
    %% Restricted cone
    {stop, normal,
     [{send, ?PACKET(?RESTRICTED_NAT)}]};
handle_info(server, {timeout, dial_verify_timeout}, State=#server_state{state=dial_verify}) ->
    lager:debug("verifier dial failed to respond for ~p : ~p", [State#server_state.observed_addr, timeout]),
    %% Could not determine
    {stop, normal,
     [{send, ?PACKET(?FAILED)}]}.



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
    lager:debug("finding peer for ~p not connected to ~p", [TargetAddr, FromAddr]),
    PeerBook = libp2p_swarm:peerbook(TID),
    {ok, FromEntry} = libp2p_peerbook:get(PeerBook, FromAddr),
    TargetCryptoAddr = libp2p_crypto:p2p_to_pubkey_bin(TargetAddr),
    lager:debug("Target crypto addr ~p", [TargetCryptoAddr]),
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
