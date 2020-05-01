-module(libp2p_secure_framed_stream_test).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    client/2,
    server/4
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3,
    handle_call/4
]).

-record(state, {
    exchanged = false,
    swarm,
    echo,
    pub_key,
    priv_key,
    rcv_key,
    send_key,
    nonce = 0
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, _Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, Args).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, [_, Echo, Swarm]) ->
    #{public := PubKey, secret := PrivKey} = enacl:kx_keypair(),
    {ok, SwarmPubKey, SignFun, _} = libp2p_swarm:keys(Swarm),
    Data = erlang:term_to_binary({key_exchange, SwarmPubKey, PubKey, SignFun(erlang:term_to_binary(PubKey))}),
    {ok, #state{
        swarm=Swarm,
        echo=Echo,
        pub_key=PubKey,
        priv_key=PrivKey
    }, Data};
init(client, _Conn, [Swarm, Echo]) ->
    #{public := PubKey, secret := PrivKey} = enacl:kx_keypair(),
    {ok, SwarmPubKey, SignFun, _} = libp2p_swarm:keys(Swarm),
    Data = erlang:term_to_binary({key_exchange, SwarmPubKey, PubKey, SignFun(erlang:term_to_binary(PubKey))}),
    {ok, #state{
        swarm=Swarm,
        echo=Echo,
        pub_key=PubKey,
        priv_key=PrivKey
    }, Data}.

handle_data(server, Data, #state{exchanged=false, pub_key=ServerPK, priv_key=ServerSK}=State) ->
    try erlang:binary_to_term(Data) of
        {key_exchange, ClientSwarmPK, ClientPK, Signature} ->
            case libp2p_crypto:verify(erlang:term_to_binary(ClientPK), Signature, ClientSwarmPK) of
                false ->
                    {stop, failed_verify, State};
                true ->
                    #{server_rx := RcvKey, server_tx := SendKey} = enacl:kx_server_session_keys(ServerPK, ServerSK, ClientPK),
                    {noreply, State#state{exchanged=true,
                                          rcv_key=RcvKey,
                                          send_key=SendKey}}
            end
    catch
        _:_ ->
            {stop, failed_bin_to_term, State}
    end;
handle_data(client, Data, #state{exchanged=false, pub_key=ClientPK, priv_key=ClientSK}=State) ->
    try erlang:binary_to_term(Data) of
        {key_exchange, ServerSwarmPK, ServerPK, Signature} ->
            case libp2p_crypto:verify(erlang:term_to_binary(ServerPK), Signature, ServerSwarmPK) of
                false ->
                    {stop, failed_verify, State};
                true ->
                    #{client_rx := RcvKey, client_tx := SendKey} = enacl:kx_client_session_keys(ClientPK, ClientSK, ServerPK),
                    {noreply, State#state{exchanged=true,
                                          rcv_key=RcvKey,
                                          send_key=SendKey}}
            end
    catch
        _:_ ->
            {stop, failed_bin_to_term, State}
    end;
handle_data(_Type, EncryptedData, #state{exchanged=true, rcv_key=RcvKey, nonce=Nonce, echo=Echo}=State) ->
    Data = enacl:aead_chacha20poly1305_decrypt(RcvKey, Nonce, <<>>, EncryptedData),
    ct:pal("~p got data ~p = ~p", [_Type, EncryptedData, Data]),
    Echo ! {echo, server, Data},
    {noreply, State#state{nonce=Nonce+1}}.

handle_info(_Type, {send, Data}, #state{exchanged=true, send_key=SendKey, nonce=Nonce}=State) ->
    EncryptedData = enacl:aead_chacha20poly1305_encrypt(SendKey, Nonce, <<>>, Data),
    ct:pal("~p got send ~p = ~p", [_Type, Data, EncryptedData]),
    {noreply, State#state{nonce=Nonce+1}, EncryptedData};
handle_info(_Type, _Msg, State) ->
    {noreply, State}.

handle_call(_Type, exchanged, _From, #state{exchanged=Ex}=State) ->
    {reply, Ex, State};
handle_call(_Type, _Msg, _From, State) ->
    {reply, ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
