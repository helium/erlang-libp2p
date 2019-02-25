-module(libp2p_secio_statem).

-behavior(gen_statem).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    code_change/3,
    callback_mode/0,
    terminate/2
]).

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    propose/3,
    indentify/3,
    select/3,
    exchange/3,
    verify/3,
    finish/3
]).

-include("../pb/libp2p_secio_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(NONCE_SIZE, 16).
-define(EXCHANGES, ["ed25519"]).
-define(CIPHERS, ["AES-128"]).
-define(HASHES, ["SHA256"]).

-record(data, {
    swarm,
    local_pubkey,
    remote_id,
    remote_pubkey,
    proposed,
    selected
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_statem:start_link({local, ?SERVER}, ?SERVER, Args, []).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Swarm, RemoteID]=Args) ->
    lager:info("init with ~p", [Args]),
    {ok, PubKey, _SigFun} = libp2p_swarm:keys(Swarm),
    Data = #data{
        swarm=Swarm,
        local_pubkey=PubKey,
        remote_id=RemoteID
    },
    self() ! next,
    {ok, propose, Data}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

callback_mode() -> state_functions.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
propose(info, next, #data{local_pubkey=PubKey}=Data) ->
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
    RemotePubKey = libp2p_crypto:bin_to_pubkey(RemotePubKeyBin),
    self() ! next,
    {next_state, indentify, Data#data{remote_pubkey=RemotePubKey,
                                      proposed={EncodedProposeOut, EncodedProposeIn}}};
propose(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
indentify(info, next, #data{swarm=Swarm, remote_id=RemoteID,
                            remote_pubkey=RemotePubKey}=Data) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    RemotePubKeyBin = libp2p_crypto:pubkey_to_bin(RemotePubKey),
    _ = case libp2p_peerbook:get(PeerBook, RemotePubKeyBin) of
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
    end,
    self() ! next,
    {next_state, select, Data};
indentify(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
select(info, next, Data) ->
    Curve = lists:last(?EXCHANGES),
    Cipher = lists:last(?CIPHERS),
    Hash = lists:last(?HASHES),
    self() ! next,
    {next_state, exchange, Data#data{selected={Curve, Cipher, Hash}}};
select(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
exchange(info, next, #data{swarm=Swarm,
                           selected={Curve, _, _},
                           proposed={EncodedProposeOut, EncodedProposeIn}}=Data) ->
    #{public := EPubKeyOut} = libp2p_crypto:generate_keys(erlang:list_to_atom(Curve)),
    EPubKeyOutBin = libp2p_crypto:pubkey_to_bin(EPubKeyOut),
    ToSign = <<EncodedProposeOut/binary, EncodedProposeIn/binary, EPubKeyOutBin/binary>>,

    {ok, _, SigFun} = libp2p_swarm:keys(Swarm),
    ExchangeOut = #libp2p_exchange_pb{
        epubkey = EPubKeyOutBin,
        signature = SigFun(ToSign)
    },
    _EncodedExchangeOut = libp2p_secio_pb:encode_msg(ExchangeOut),

    % TODO: Send exchange packet
    % TODO: Receive other side exchange packet
    EncodedExchangeIn = <<>>,
    ExchangeIn = libp2p_secio_pb:decode_msg(EncodedExchangeIn, libp2p_exchange_pb),

    self() ! ExchangeIn,
    {next_state, verify, Data};
exchange(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
verify(info, ExchangeIn, #data{remote_pubkey=RemotePubKey,
                               proposed={EncodedProposeOut, EncodedProposeIn}}=Data) ->
    EPubKeyInBin = ExchangeIn#libp2p_exchange_pb.epubkey,
    ToVerify = <<EncodedProposeOut/binary, EncodedProposeIn/binary, EPubKeyInBin/binary>>,
    true = libp2p_crypto:verify(ToVerify, ExchangeIn#libp2p_exchange_pb.signature, RemotePubKey),
    self() ! next,
    {next_state, finish, Data};
verify(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
finish(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_event(_EventType, _EventContent, Data) ->
    lager:warning("ignoring event [~p] ~p", [_EventType, _EventContent]),
    {keep_state, Data}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-endif.
