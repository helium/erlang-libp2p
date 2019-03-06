-module(libp2p_framed_stream).

-behavior(gen_server).
-behavior(libp2p_info).


% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
% API
-export([client/3, server/3, server/4, send/2, send/3, recv/2,
         close/1, close_state/1, addr_info/1, connection/1, session/1]).
%% libp2p_info
-export([info/1]).

-define(RECV_TIMEOUT, 5000).
-define(SEND_TIMEOUT, 5000).

-type response() :: binary().
-type handle_data_result() ::
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type init_result() ::
        {ok, ModState :: any()} |
        {ok, ModState :: any(), Response::response()} |
        {stop, Reason :: term()} |
        {stop, Reason :: term(), Response::response()}.
-type handle_info_result() ::
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type handle_call_result() ::
        {reply, Reply :: term(), ModState :: any()} |
        {reply, Reply :: term(), ModState :: any(), Response::response()} |
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), Reply :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), Reply :: term(), ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type handle_cast_result() ::
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type handle_send_result() ::
        {ok, Action::send_result_action(), Data::binary(), Timeout::non_neg_integer(), ModState :: any()} |
        {error, term(), ModState :: any()}.

-type kind() :: server | client.
-type send_result_action() ::
        noreply |
        {reply, From :: pid()} |
        {reply, From :: pid(), Reply :: term()} |
        {stop, Reason :: term()} |
        {stop, Reason :: term(), From :: pid(), Reply :: term()}.

-export_type([init_result/0,
              kind/0,
              handle_info_result/0,
              handle_call_result/0,
              handle_cast_result/0,
              handle_data_result/0]).

-callback server(libp2p_connection:connection(), string(), ets:tab(), [any()]) ->
    no_return() |
    {error, term()}.
-callback client(libp2p_connection:connection(), [any()]) -> {ok, pid()} | {error, term()} | ignore.

-callback init(kind(), libp2p_connection:connection(), [any()]) -> init_result().
-callback handle_data(kind(), any(), any()) -> handle_data_result().
-callback handle_info(kind(), term(), any()) -> handle_info_result().
-callback handle_call(kind(), Msg::term(), From::term(), ModState::any()) -> handle_call_result().
-callback handle_cast(kind(), term(), any()) -> handle_cast_result().
-callback handle_send(kind(), From::pid(), Data::any(), Tmeout::non_neg_integer(), any()) -> handle_send_result().

-optional_callbacks([handle_info/3, handle_call/4, handle_cast/3, handle_send/5]).

-record(state, {
    module :: atom(),
    state :: any(),
    kind :: kind(),
    connection :: libp2p_connection:connection(),
    sends=#{} :: #{ Timer::reference() => From::pid() },
    send_pid :: pid(),
    secured = false :: boolean(),
    parent :: pid(),
    exchanged = false :: boolean(),
    swarm :: pid(),
    args :: [any()],
    pub_key :: binary(),
    priv_key :: binary(),
    rcv_key :: binary(),
    send_key :: binary(),
    rcv_nonce = 0 :: non_neg_integer(),
    send_nonce = 0 :: non_neg_integer()
}).

%%
%% Client
%%

-spec client(atom(), libp2p_connection:connection(), [any()]) -> {ok, pid()} | {error, term()} | ignore.
client(Module, Connection, Args) ->
    case gen_server:start_link(?MODULE, {client, Module, Connection, [self()|Args]}, []) of
        {ok, Pid} ->
            libp2p_connection:controlling_process(Connection, Pid),
            receive
                {?MODULE, rdy} -> {ok, Pid}
            after 2500 ->
                {error, rdy_timeout}
            end;
        {error, Error} -> {error, Error};
        Other -> Other
    end.

init({client, Module, Connection, Args}) ->
    case init_module(client, Module, Connection, Args) of
        {ok, State} -> {ok, State};
        {error, Error} -> {stop, Error}
    end.


%%
%% Server
%%
-spec server(atom(), libp2p_connection:connection(), [any()]) -> no_return() | {error, term()}.
server(Module, Connection, Args) ->
    case init_module(server, Module, Connection, Args) of
        {ok, State} -> gen_server:enter_loop(?MODULE, [], State);
        {error, Error} -> {error, Error}
    end.

server(Connection, Path, _TID, [Module | Args]) ->
    server(Module, Connection, [Path | Args]).

%%
%% libp2p_info
%%

-spec info(pid()) -> map().
info(Pid) ->
    catch gen_server:call(Pid, info).

%%
%% Common
%%

-spec init_module(atom(), atom(), libp2p_connection:connection(), [any()]) -> {ok, #state{}} | {error, term()}.
init_module(client=Kind, Module, Connection, [Parent|Args]) ->
    SendPid = spawn_link(libp2p_connection:mk_async_sender(self(), Connection)),
    case proplists:get_value(secured, Args, false) of
        Swarm when is_pid(Swarm) ->
            #{public := PubKey, secret := PrivKey} = enacl:kx_keypair(),
            {ok, _, SignFun} = libp2p_swarm:keys(Swarm),
            Data = erlang:term_to_binary({key_exchange, PubKey, SignFun(erlang:term_to_binary(PubKey))}),
            State0 = #state{
                kind=Kind,
                module=Module,
                connection=Connection,
                send_pid=SendPid,
                secured=true,
                exchanged=false,
                swarm=Swarm,
                args=Args,
                pub_key=PubKey,
                priv_key=PrivKey,
                parent=Parent
            },
            State1 = handle_fdset(send_key(Data, State0)),
            {ok, State1};
        _ ->
            Parent ! {?MODULE, rdy},
            init_module(Kind, Module, Connection, Args, SendPid)
    end;
init_module(Kind, Module, Connection, Args) ->
    erlang:put(stream_type, {Kind, Module}),
    SendPid = spawn_link(libp2p_connection:mk_async_sender(self(), Connection)),
    case proplists:get_value(secured, Args, false) of
        Swarm when is_pid(Swarm) ->
            #{public := PubKey, secret := PrivKey} = enacl:kx_keypair(),
            {ok, _, SignFun} = libp2p_swarm:keys(Swarm),
            Data = erlang:term_to_binary({key_exchange, PubKey, SignFun(erlang:term_to_binary(PubKey))}),
            State0 = #state{
                kind=Kind,
                module=Module,
                connection=Connection,
                send_pid=SendPid,
                secured=true,
                exchanged=false,
                swarm=Swarm,
                args=Args,
                pub_key=PubKey,
                priv_key=PrivKey
            },
            State1 = handle_fdset(send_key(Data, State0)),
            {ok, State1};
        _ ->
            init_module(Kind, Module, Connection, Args, SendPid)
    end.

-spec init_module(atom(), atom(), libp2p_connection:connection(), [any()], pid()) -> {ok, #state{}} | {error, term()}.
init_module(Kind, Module, Connection, Args, SendPid) ->
    case Module:init(Kind, Connection, Args) of
        {ok, ModuleState} ->
            {ok, handle_fdset(#state{kind=Kind,
                                     connection=Connection, send_pid=SendPid,
                                     module=Module, state=ModuleState})};
        {ok, ModuleState, Response} ->
            {ok, handle_fdset(handle_resp_send(noreply, Response,
                                               #state{kind=Kind,
                                                      connection=Connection, send_pid=SendPid,
                                                      module=Module, state=ModuleState}))};
        {stop, Reason} ->
            libp2p_connection:close(Connection),
            {error, Reason};
        {stop, Reason, Response} ->
            {ok, handle_fdset(handle_resp_send({stop, Reason}, Response,
                                               #state{kind=Kind, connection=Connection, send_pid=SendPid,
                                                      module=Module, state=undefined}))}
    end.

handle_info({inert_read, _, _}, #state{
                                    kind=server,
                                    module=Module,
                                    connection=Connection,
                                    send_pid=SendPid,
                                    secured=true,
                                    exchanged=false,
                                    args=Args,
                                    pub_key=ServerPK,
                                    priv_key=ServerSK
                                }=State0) ->
    case recv(Connection, ?RECV_TIMEOUT) of
        {error, timeout} ->
            {noreply, State0};
        {error, closed} ->
            {stop, normal, State0};
        {error, Error}  ->
            lager:notice("framed inert RECV ~p, ~p", [Error, Connection]),
            {stop, {error, Error}, State0};
        {ok, Data} ->
            {key_exchange, ClientPK, Signature} = erlang:binary_to_term(Data),

            {ok, Session} = libp2p_connection:session(Connection),
            libp2p_session:identify(Session, self(), my_data),
            {ok, Identify} = receive
                {handle_identify, my_data, R} -> R
                after 1000 -> error(timeout)
            end,
            PKBin = libp2p_identify:pubkey_bin(Identify),
            ClientSwarmPK = libp2p_crypto:bin_to_pubkey(PKBin),

            case libp2p_crypto:verify(erlang:term_to_binary(ClientPK), Signature, ClientSwarmPK) of
                false ->
                    {stop, {error, failed_verify}, State0};
                true ->
                    #{server_rx := RcvKey, server_tx := SendKey} = enacl:kx_server_session_keys(ServerPK, ServerSK, ClientPK),
                    case init_module(server, Module, Connection, Args, SendPid) of
                        {error, _}=Error ->
                            {stop, Error, State0};
                        {ok, State1} ->
                            {noreply, State1#state{
                                secured=true,
                                exchanged=true,
                                rcv_key=RcvKey,
                                send_key=SendKey
                            }}
                    end
            end
    end;
handle_info({inert_read, _, _}, #state{
                                    kind=client,
                                    module=Module,
                                    connection=Connection,
                                    send_pid=SendPid,
                                    secured=true,
                                    parent=Parent,
                                    exchanged=false,
                                    args=Args,
                                    pub_key=ClientPK,
                                    priv_key=ClientSK
                                }=State0) ->
    case recv(Connection, ?RECV_TIMEOUT) of
        {error, timeout} ->
            {noreply, State0};
        {error, closed} ->
            {stop, normal, State0};
        {error, Error}  ->
            lager:notice("framed inert RECV ~p, ~p", [Error, Connection]),
            {stop, {error, Error}, State0};
        {ok, Data} ->
            {key_exchange, ServerPK, Signature} = erlang:binary_to_term(Data),

            {ok, Session} = libp2p_connection:session(Connection),
            libp2p_session:identify(Session, self(), my_data),
            {ok, Identify} = receive
                {handle_identify, my_data, R} -> R
                after 1000 -> error(timeout)
            end,
            PKBin = libp2p_identify:pubkey_bin(Identify),
            ServerSwarmPK = libp2p_crypto:bin_to_pubkey(PKBin),

            case libp2p_crypto:verify(erlang:term_to_binary(ServerPK), Signature, ServerSwarmPK) of
                false ->
                    {stop, {error, failed_verify}, State0};
                true ->
                    #{client_rx := RcvKey, client_tx := SendKey} = enacl:kx_client_session_keys(ClientPK, ClientSK, ServerPK),
                    case init_module(client, Module, Connection, Args, SendPid) of
                        {error, _}=Error ->
                            {stop, Error, State0};
                        {ok, State1} ->
                            Parent ! {?MODULE, rdy},
                            {noreply, State1#state{
                                secured=true,
                                exchanged=true,
                                rcv_key=RcvKey,
                                send_key=SendKey
                            }}
                    end
            end
    end;
handle_info({inert_read, _, _}, #state{
                                    kind=Kind,
                                    connection=Connection,
                                    module=Module,
                                    state=ModuleState0,
                                    secured=true,
                                    exchanged=true,
                                    rcv_key=RcvKey,
                                    rcv_nonce=Nonce
                                }=State) ->
    case recv(Connection, ?RECV_TIMEOUT) of
        {error, timeout} ->
            %% timeouts are fine and not an error we want to propogate because there's no waiter
            {noreply, State};
        {error, closed} ->
            %% This attempts to avoid a large number of errored stops
            %% when a connection is closed, which happens "normally"
            %% in most cases.
            {stop, normal, State};
        {error, Error}  ->
            lager:notice("framed inert RECV ~p, ~p", [Error, Connection]),
            {stop, {error, Error}, State};
        {ok, EncryptedData} ->
            case enacl:aead_chacha20poly1305_decrypt(RcvKey, Nonce, <<>>, EncryptedData) of
                {error, _Reason} ->
                    lager:warning("error decrypting packet ~p ~p", [_Reason, EncryptedData]),
                    {noreply, handle_fdset(State#state{rcv_nonce=Nonce+1})};
                Bin ->
                    case Module:handle_data(Kind, Bin, ModuleState0) of
                        {noreply, ModuleState}  ->
                            {noreply, handle_fdset(State#state{state=ModuleState, rcv_nonce=Nonce+1})};
                        {noreply, ModuleState, Response} ->
                            {noreply, handle_fdset(handle_resp_send(noreply, Response, State#state{state=ModuleState, rcv_nonce=Nonce+1}))};
                        {stop, Reason, ModuleState} ->
                            {stop, Reason, State#state{state=ModuleState, rcv_nonce=Nonce+1}};
                        {stop, Reason, ModuleState, Response} ->
                            {noreply, handle_fdset(handle_resp_send({stop, Reason}, Response, State#state{state=ModuleState, rcv_nonce=Nonce+1}))}
                    end
            end
    end;
handle_info({inert_read, _, _}, State=#state{kind=Kind, connection=Connection,
                                             module=Module, state=ModuleState0}) ->
    case recv(Connection, ?RECV_TIMEOUT) of
        {error, timeout} ->
            %% timeouts are fine and not an error we want to propogate because there's no waiter
            {noreply, State};
        {error, closed} ->
            %% This attempts to avoid a large number of errored stops
            %% when a connection is closed, which happens "normally"
            %% in most cases.
            {stop, normal, State};
        {error, Error}  ->
            lager:notice("framed inert RECV ~p, ~p", [Error, Connection]),
            {stop, {error, Error}, State};
        {ok, Bin} ->
            case Module:handle_data(Kind, Bin, ModuleState0) of
                {noreply, ModuleState}  ->
                    {noreply, handle_fdset(State#state{state=ModuleState})};
                {noreply, ModuleState, Response} ->
                    {noreply, handle_fdset(handle_resp_send(noreply, Response, State#state{state=ModuleState}))};
                {stop, Reason, ModuleState} ->
                    {stop, Reason, State#state{state=ModuleState}};
                {stop, Reason, ModuleState, Response} ->
                    {noreply, handle_fdset(handle_resp_send({stop, Reason}, Response, State#state{state=ModuleState}))}
            end
    end;
handle_info({send_result, Key, Result}, State=#state{sends=Sends}) ->
    case maps:take(Key, Sends) of
        error -> {noreply, State};
        {{Timer, Info}, NewSends} ->
            erlang:cancel_timer(Timer),
            handle_send_result(Info, Result, State#state{sends=NewSends})
    end;
handle_info(Msg, State=#state{kind=Kind, module=Module, state=ModuleState0}) ->
    case erlang:function_exported(Module, handle_info, 3) of
        true -> case Module:handle_info(Kind, Msg, ModuleState0) of
                    {noreply, ModuleState}  ->
                        {noreply, State#state{state=ModuleState}};
                    {noreply, ModuleState, Response} ->
                        {noreply, handle_resp_send(noreply, Response, State#state{state=ModuleState})};
                    {stop, Reason, ModuleState} ->
                        {stop, Reason, State#state{state=ModuleState}};
                    {stop, Reason, ModuleState, Response} ->
                        {noreply, handle_resp_send({stop, Reason}, Response, State#state{state=ModuleState})}
                end;
        false -> {noreply, State}
    end.

handle_call(close_state, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:close_state(Connection), State};
handle_call(addr_info, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:addr_info(Connection), State};
handle_call({send, Data, Timeout}, From, State=#state{kind=Kind, module=Module, state=ModuleState0}) ->
    case erlang:function_exported(Module, handle_send, 5) of
        true -> case Module:handle_send(Kind, From, Data, Timeout, ModuleState0) of
                    {error, Error, ModuleState} -> {reply, {error, Error}, State#state{state=ModuleState}};
                    {ok, ResultAction, NewData, NewTimeout, ModuleState} ->
                        {noreply, handle_resp_send(ResultAction, NewData, NewTimeout,
                                                   State#state{state=ModuleState})}
                end;
        false ->
            {noreply, handle_resp_send({reply, From}, Data, Timeout, State)}
    end;
handle_call(connection, _From, State=#state{connection=Connection}) ->
    {reply, Connection, State};
handle_call(info, _From, State=#state{kind=Kind, module=Module}) ->
    Info = #{
             pid => self(),
             module => ?MODULE,
             kind => Kind,
             handler => Module
            },
    {reply, Info, State};
handle_call(Msg, From, State=#state{kind=Kind, module=Module, state=ModuleState0}) ->
    case erlang:function_exported(Module, handle_call, 4) of
        true -> case Module:handle_call(Kind, Msg, From, ModuleState0) of
                    {reply, Reply, ModuleState} ->
                        {reply, Reply, State#state{state=ModuleState}};
                    {reply, Reply, ModuleState, Response} ->
                        {noreply, handle_resp_send({reply, From, Reply}, Response, State#state{state=ModuleState})};
                    {noreply, ModuleState}  ->
                        {noreply, State#state{state=ModuleState}};
                    {noreply, ModuleState, Response} ->
                        {noreply, handle_resp_send(noreply, Response, State#state{state=ModuleState})};
                    {stop, Reason, ModuleState, Response} when is_binary(Response) ->
                        {noreply, handle_resp_send({stop, Reason}, Response, State#state{state=ModuleState})};
                    {stop, Reason, Reply, ModuleState} ->
                        {stop, Reason, Reply, State#state{state=ModuleState}};
                    {stop, Reason, ModuleState} ->
                        {stop, Reason, State#state{state=ModuleState}};
                    {stop, Reason, Reply, ModuleState, Response} ->
                        {noreply, handle_resp_send({stop, Reason, From, Reply}, Response, State#state{state=ModuleState})}
                end;
        false -> [reply, ok, State]
    end.

handle_cast(close, State=#state{connection=Connection}) ->
    libp2p_connection:close(Connection),
    {stop, normal, State};
handle_cast(Request, State=#state{kind=Kind, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, handle_cast, 3) of
        true -> case Module:handle_cast(Kind, Request, ModuleState) of
                    {noreply, ModuleState}  ->
                        {noreply, State#state{state=ModuleState}};
                    {noreply, ModuleState, Response} ->
                        {noreply, handle_resp_send(noreply, Response, State#state{state=ModuleState})};
                    {stop, Reason, ModuleState} ->
                        {stop, Reason, State#state{state=ModuleState}};
                    {stop, Reason, ModuleState, Response} ->
                        {noreply, handle_resp_send({stop, Reason}, Response, State#state{state=ModuleState})}
                    end;
        false -> {noreply, State}
    end.

terminate(Reason, #state{send_pid=SendPid, kind=Kind, connection=Connection, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, terminate, 3) of
        true -> Module:terminate(Kind, Reason, ModuleState);
        false -> ok
    end,
    unlink(SendPid),
    erlang:exit(SendPid, kill),
    libp2p_connection:fdclr(Connection),
    libp2p_connection:close(Connection).

call(Pid, Cmd) ->
    call(Pid, Cmd, 5000).

call(Pid, Cmd, Timeout) ->
    try
        gen_server:call(Pid, Cmd, Timeout)
    catch
        exit:{noproc, _} ->
            {error, closed};
        exit:{normal, _} ->
            {error, closed};
        exit:{shutdown, _} ->
            {error, closed}
    end.

close(Pid) ->
    gen_server:cast(Pid, close).

close_state(Pid) ->
    case call(Pid, close_state) of
        {error, closed} -> closed;
        R -> R
    end.

send(Pid, Data) ->
    send(Pid, Data, ?SEND_TIMEOUT).

send(Pid, Data, Timeout) ->
    call(Pid, {send, Data, Timeout}, infinity).

addr_info(Pid) ->
    call(Pid, addr_info).

connection(Pid) ->
    call(Pid, connection).

-spec session(pid()) -> {ok, pid()} | {error, term()}.
session(Pid) ->
    case connection(Pid) of
        {error, Reason} ->
            {error, Reason};
        Connection ->
            libp2p_connection:session(Connection)
    end.

-spec recv(libp2p_connection:connection(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
recv(Connection, Timeout) ->
    case libp2p_connection:recv(Connection, 4, Timeout) of
        {error, Error} -> {error, Error};
        {ok, <<Size:32/little-unsigned-integer>>} ->
            %% TODO: Limit max message size we're willing to
            %% TODO if we read the prefix length, but time out on the payload, we should handle this?
            case libp2p_connection:recv(Connection, Size, Timeout) of
                {ok, Data} when byte_size(Data) == Size -> {ok, Data};
                {ok, _Data} -> {error, frame_size_mismatch};
                {error, Error} -> {error, Error}
            end
    end.

%% Internal
%%


-spec handle_fdset(#state{}) -> #state{}.
handle_fdset(State=#state{connection=Connection}) ->
    libp2p_connection:fdset(Connection),
    State.

-spec handle_resp_send(send_result_action(), binary(), #state{}) -> #state{}.
handle_resp_send(Action, Data, State=#state{}) ->
    handle_resp_send(Action, Data, ?SEND_TIMEOUT, State).


send_key(Data, #state{send_pid=SendPid}=State) ->
    Key = make_ref(),
    Bin = <<(byte_size(Data)):32/little-unsigned-integer, Data/binary>>,
    SendPid ! {send, Key, Bin},
    State.

-spec handle_resp_send(send_result_action(), binary(), non_neg_integer(), #state{}) -> #state{}.
handle_resp_send(Action, Data, Timeout, #state{
                                            sends=Sends,
                                            send_pid=SendPid,
                                            secured=true,
                                            exchanged=true,
                                            send_key=SendKey,
                                            send_nonce=Nonce
                                        }=State) ->
    case enacl:aead_chacha20poly1305_encrypt(SendKey, Nonce, <<>>, Data) of
        {error, _Reason} ->
            lager:warning("failed to encrypt ~p : ~p", [{Nonce, Data}, _Reason]),
            State;
        EncryptedData ->
            Key = make_ref(),
            Timer = erlang:send_after(Timeout, self(), {send_result, Key, {error, timeout}}),
            Bin = <<(byte_size(EncryptedData)):32/little-unsigned-integer, EncryptedData/binary>>,
            SendPid ! {send, Key, Bin},
            State#state{sends=maps:put(Key, {Timer, Action}, Sends), send_nonce=Nonce+1}
    end;
handle_resp_send(Action, Data, Timeout, State=#state{sends=Sends, send_pid=SendPid}) ->
    Key = make_ref(),
    Timer = erlang:send_after(Timeout, self(), {send_result, Key, {error, timeout}}),
    Bin = <<(byte_size(Data)):32/little-unsigned-integer, Data/binary>>,
    SendPid ! {send, Key, Bin},
    State#state{sends=maps:put(Key, {Timer, Action}, Sends)}.


-spec handle_send_result(send_result_action(), ok | {error, term()}, #state{}) ->
                                {noreply, #state{}} |
                                {stop, Reason::term(), #state{}}.
handle_send_result({reply, From}, Result, State=#state{}) ->
    gen_server:reply(From, Result),
    {noreply, State};
handle_send_result({reply, From, Reply}, ok, State=#state{}) ->
    gen_server:reply(From, Reply),
    {noreply, State};
handle_send_result({reply, From, Reply}, {error, closed}, State=#state{}) ->
    gen_server:reply(From, Reply),
    {stop, normal, State};
handle_send_result(noreply, ok, State=#state{}) ->
    {noreply, State};
handle_send_result({stop, Reason}, ok, State=#state{}) ->
    {stop, Reason, State};
handle_send_result({stop, Reason, From, Reply}, ok, State=#state{}) ->
    gen_server:reply(From, Reply),
    {stop, Reason, State};
handle_send_result({stop, Reason, From, Reply}, {error, closed}, State=#state{}) ->
    gen_server:reply(From, Reply),
    {stop, Reason, State};
handle_send_result(_, {error, timeout}, State=#state{}) ->
    {stop, normal, State};
handle_send_result(_, {error, closed}, State=#state{}) ->
    {stop, normal, State};
handle_send_result(_, {error, Error}, State=#state{})  ->
    {stop, {error, Error}, State}.
