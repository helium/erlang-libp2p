-module(libp2p_secio).

-export([
    encrypt/2
]).

-include("../pb/libp2p_secio_pb.hrl").

-define(NONCE_SIZE, 16).
-define(EXCHANGES, ["ed25519"]).
-define(CIPHERS, ["AES-128"]).
-define(HASHES, ["SHA256"]).

encrypt(Swarm, RemoteID) ->
    {ok, PubKey, SigFun} = libp2p_swarm:keys(Swarm),
    % STEP 1: Create and send propose packet
    ProposeOut = #libp2p_propose_pb{
        rand = crypto:strong_rand_bytes(?NONCE_SIZE),
        pubkey = libp2p_crypto:pubkey_to_bin(PubKey),
        exchanges = ?EXCHANGES,
        ciphers = ?CIPHERS,
        hashes = ?HASHES
    },
    EncodedProposeOut = libp2p_secio_pb:encode_msg(ProposeOut),

    % TODO: Send propose packet
    % TODO: Receive other side propose packet

    EncodedProposeIn = <<>>,
    ProposeIn = libp2p_secio_pb:decode_msg(EncodedProposeIn, libp2p_propose_pb),
    RemotePubKeyBin = ProposeIn#libp2p_propose_pb.pubkey,

    % STEP 2: Identify & make sure resp math remote peer dialed
    ok = identify(Swarm, RemoteID, RemotePubKeyBin),

    % STEP 3: Select/agree on best encryption parameters
    % TODO: Need to actually compare and select
    Curve = lists:last(?EXCHANGES),
    _Cipher = lists:last(?CIPHERS),
    _Hash = lists:last(?HASHES),

    % STEP 4: Generate EphemeralPubKey and send exchange
    #{public := EPubKeyOut} = libp2p_crypto:generate_keys(erlang:list_to_atom(Curve)),
    EPubKeyOutBin = libp2p_crypto:pubkey_to_bin(EPubKeyOut),
    ToSign = <<EncodedProposeOut/binary, EncodedProposeIn/binary, EPubKeyOutBin/binary>>,

    ExchangeOut = #libp2p_exchange_pb{
        epubkey = EPubKeyOutBin,
        signature = SigFun(ToSign)
    },
    _EncodedExchangeOut = libp2p_secio_pb:encode_msg(ExchangeOut),

    % TODO: Send exchange packet
    % TODO: Receive other side exchange packet

    EncodedExchangeIn = <<>>,
    ExchangeIn = libp2p_secio_pb:decode_msg(EncodedExchangeIn, libp2p_exchange_pb),

    % STEP 5: Verify echange
    EPubKeyInBin = ExchangeIn#libp2p_exchange_pb.epubkey,
    ToVerify = <<EncodedProposeOut/binary, EncodedProposeIn/binary, EPubKeyInBin/binary>>,
    true = libp2p_crypto:verify(ToVerify, ExchangeIn#libp2p_exchange_pb.signature, libp2p_crypto:bin_to_pubkey(RemotePubKeyBin)),

    ok.

identify(Swarm, RemoteID, RemotePubKey) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    case libp2p_peerbook:get(PeerBook, RemotePubKey) of
        {error, _}=Error ->
            % TODO: if peer not found maybe dial it?
            Error;
        {ok, Peer} ->
            case libp2p_peer:pubkey_bin(Peer) of
                RemoteID ->
                    ok;
                _ ->
                    {error, bad_peer}
            end
    end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").



-endif.
