% TODO:
% 1. Where to setup server side? Should we do like multi stream server?
% 2. How do you encrypt the connection/session? And then decrypt?
% 3. Should statem die after it is done?

-module(libp2p_secio_statem).

-behavior(gen_statem).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1
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
    transport :: pid(),
    swarm :: pid(),
    connection :: libp2p_connection:connection(),
    local_pubkey :: libp2p_crypto:pubkey(),
    remote_pubkey :: undefined | libp2p_crypto:pubkey(),
    proposed :: undefined | {binary(), binary()},
    selected :: undefined | {string(), string(), string()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start(Args) ->
    gen_statem:start(?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Transport, Swarm, Connection]=Args) ->
    lager:info("init with ~p", [Args]),
    {ok, PubKey, _SigFun} = libp2p_swarm:keys(Swarm),
    Data = #data{
        transport=Transport,
        swarm=Swarm,
        connection=Connection,
        local_pubkey=PubKey
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
propose(info, next, #data{connection=Conn, local_pubkey=PubKey}=Data) ->
    ProposeOut = #libp2p_propose_pb{
        rand = crypto:strong_rand_bytes(?NONCE_SIZE),
        pubkey = libp2p_crypto:pubkey_to_bin(PubKey),
        exchanges = ?EXCHANGES,
        ciphers = ?CIPHERS,
        hashes = ?HASHES
    },
    EncodedProposeOut = libp2p_secio_pb:encode_msg(ProposeOut),
    ok = libp2p_secio:write(Conn, EncodedProposeOut),
    case libp2p_secio:read(Conn) of
        {error, _Reason}=Error ->
            lager:error("failed to send proposal ~p: ~p", [ProposeOut, _Reason]),
            {stop, Error};
        EncodedProposeIn ->
            ProposeIn = libp2p_secio_pb:decode_msg(EncodedProposeIn, libp2p_propose_pb),
            RemotePubKeyBin = ProposeIn#libp2p_propose_pb.pubkey,
            RemotePubKey = libp2p_crypto:bin_to_pubkey(RemotePubKeyBin),
            next(indentify, Data#data{remote_pubkey=RemotePubKey,
                                      proposed={EncodedProposeOut, EncodedProposeIn}})
    end;
propose(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
indentify(info, next, #data{swarm=Swarm, remote_pubkey=RemotePubKey}=Data) ->
    PeerBook = libp2p_swarm:peerbook(Swarm),
    RemotePubKeyBin = libp2p_crypto:pubkey_to_bin(RemotePubKey),
    _ = case libp2p_peerbook:get(PeerBook, RemotePubKeyBin) of
        {error, _Reason}=Error ->
            lager:error("failed to get peer ~p: ~p", [RemotePubKeyBin, _Reason]),
            {stop, Error};
        {ok, _Peer} ->
            % TODO: We should compare remote peer from connection with this (not sure how to right now)
            next(select, Data)
    end;
indentify(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
select(info, next, Data) ->
    % TODO: Actually select something
    Curve = lists:last(?EXCHANGES),
    Cipher = lists:last(?CIPHERS),
    Hash = lists:last(?HASHES),
    next(select,  Data#data{selected={Curve, Cipher, Hash}});
select(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
exchange(info, next, #data{swarm=Swarm,
                           connection=Conn,
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
    EncodedExchangeOut = libp2p_secio_pb:encode_msg(ExchangeOut),
    ok = libp2p_secio:write(Conn, EncodedExchangeOut),
    case libp2p_secio:read(Conn) of
        {error, _Reason}=Error ->
            lager:error("failed to send proposal ~p: ~p", [ExchangeOut, _Reason]),
            {stop, Error};
        EncodedExchangeIn ->
            ExchangeIn = libp2p_secio_pb:decode_msg(EncodedExchangeIn, libp2p_exchange_pb),
            next(verify, {next, ExchangeIn}, Data)
    end;
exchange(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
verify(info, {next, ExchangeIn}, #data{remote_pubkey=RemotePubKey,
                                       proposed={EncodedProposeOut, EncodedProposeIn}}=Data) ->
    EPubKeyInBin = ExchangeIn#libp2p_exchange_pb.epubkey,
    ToVerify = <<EncodedProposeOut/binary, EncodedProposeIn/binary, EPubKeyInBin/binary>>,
    true = libp2p_crypto:verify(ToVerify, ExchangeIn#libp2p_exchange_pb.signature, RemotePubKey),
    next(finish,  Data);
verify(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
finish(info, next, #data{transport=Transport}=Data) ->
    Transport ! secio_negotiated,
    {keep_state, Data};
finish(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

next(State, Data) ->
    next(State, next, Data).

next(State, Msg, Data) ->
    self() ! Msg,
    {next_state, State, Data}.

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
