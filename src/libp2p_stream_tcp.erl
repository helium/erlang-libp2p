-module(libp2p_stream_tcp).

-behavior(libp2p_stream_transport).
-behavior(acceptor).

-type opts() :: #{socket => gen_tcp:socket(),
                  mod => atom(),
                  send_fn => libp2p_stream_transport:send_fn()
                 }.

-export_type([opts/0]).

-define(DEFAULT_CONNECT_TIMEOUT, 5000).

%%% libp2p_stream_transport
-export([start_link/2,
         init/2,
         handle_call/3,
         handle_info/2,
         handle_packet/3,
         handle_action/2,
         terminate/2]).

%% API
-export([command/2, addr_info/1]).
%% acceptor
-export([acceptor_init/3,
         acceptor_continue/3,
         acceptor_terminate/2]).

-record(state, {
                kind :: libp2p_stream:kind(),
                active=false :: libp2p_stream:active(),
                socket=undefined :: undefined | gen_tcp:socket(),
                listen_socket_monitor=make_ref() :: reference(),
                socket_active=false :: libp2p_stream:active(),
                mod :: atom(),
                mod_state=undefined :: any(),
                mod_base_opts=#{} :: map(),
                data= <<>> :: binary()
               }).

command(Pid, Cmd) ->
    libp2p_stream_transport:command(Pid, Cmd).

addr_info(Pid) when is_pid(Pid) ->
    command(Pid, stream_addr_info);
addr_info(Sock) ->
    {ok, LocalAddr} = inet:sockname(Sock),
    {ok, RemoteAddr} = inet:peername(Sock),
    {libp2p_transport_tcp:to_multiaddr(LocalAddr), libp2p_transport_tcp:to_multiaddr(RemoteAddr)}.


%% acceptor callbacks
%%

acceptor_init(_SockName, LSock, Opts) ->
    MRef = monitor(port, LSock),
    {ok, Opts#{listen_socket_monitor => MRef}}.

acceptor_continue(_PeerName, Sock, Opts) ->
    libp2p_stream_transport:enter_loop(?MODULE, server, Opts#{socket => Sock,
                                                              send_fn => mk_send_fn(Sock)}).

acceptor_terminate(_Reason, _) ->
    exit(normal).

start_link(Kind, Opts) ->
    libp2p_stream_transport:start_link(?MODULE, Kind, Opts).

-spec init(libp2p_stream:kind(), Opts::opts()) -> libp2p_stream_transport:init_result().
init(Kind, Opts=#{handler_fn := HandlerFun}) ->
    init(Kind, maps:remove(handler_fn, Opts#{ handlers => HandlerFun() }));
init(Kind, Opts=#{handlers := Handlers}) ->
    ModOpts = maps:get(mod_opts, Opts, #{}),
    NewOpts = Opts#{ mod => libp2p_stream_multistream,
                     mod_opts => maps:merge(ModOpts, #{ handlers => Handlers})
                   },
    init(Kind, maps:remove(handlers, NewOpts));
init(Kind, Opts=#{mod := Mod}) ->
    erlang:process_flag(trap_exit, true),
    libp2p_stream_transport:stream_stack_update(Mod, Kind),
    self() ! {init_mod, Opts},
    {ok, #state{mod=Mod, kind=Kind}}.


handle_call(stream_addr_info, _From, State=#state{}) ->
    {reply, libp2p_stream_transport:stream_addr_info(), State};

handle_call(Cmd, From, State=#state{mod=Mod, mod_state=ModState, kind=Kind}) ->
    case erlang:function_exported(Mod, handle_command, 4) of
        true->
            Result = Mod:handle_command(Kind, Cmd, From, ModState),
            handle_command_result(Result, State);
        false ->
            lager:warning("Unhandled ~p callback call: ~p", [Kind, Cmd]),
            {reply, ok, State}
    end.


-spec handle_command_result(libp2p_stream:handle_command_result(), #state{}) ->
                                   {reply, any(), #state{}, libp2p_stream:action()} |
                                   {noreply, #state{}, libp2p_stream:actions()}.
handle_command_result({reply, Reply, ModState}, State=#state{}) ->
    handle_command_result({reply, Reply, ModState, []}, State);
handle_command_result({reply, Reply, ModState, Actions}, State=#state{}) ->
    {reply, Reply, State#state{mod_state=ModState}, Actions};
handle_command_result({noreply, ModState}, State=#state{}) ->
    handle_command_result({noreply, ModState, []}, State);
handle_command_result({noreply, ModState, Actions}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}, Actions}.

handle_info({init_mod, Opts=#{ socket := Sock }}, State=#state{mod=Mod, kind=Kind}) ->
    libp2p_stream_transport:stream_addr_info_update(addr_info(Sock)),
    case Kind of
        server -> ok;
        client ->
            ok = inet:setopts(Sock, [binary,
                                     {nodelay, true},
                                     {active, false},
                                     {packet, raw}])
    end,
    SendFun = maps:get(send_fn, Opts, mk_send_fn(Sock)),
    ModOpts = maps:get(mod_opts, Opts, #{}),
    ModBaseOpts = #{ send_fn => SendFun,
                     stream_handler => maps:get(stream_handler, Opts, undefined)
                   },
    ListenSocketMonitor = maps:get(listen_socket_monitor, Opts, undefined),
    MkState = fun(ModState) ->
                      State#state{mod_state=ModState,
                                  socket=Sock,
                                  mod_base_opts=ModBaseOpts,
                                  listen_socket_monitor=ListenSocketMonitor}
              end,
    case Mod:init(Kind, maps:merge(ModOpts, ModBaseOpts)) of
        {ok, ModState, Actions} ->
            {noreply, MkState(ModState), [{send_fn, SendFun} | Actions]};
        {stop, Reason} ->
            {stop, Reason, State};
        {stop, Reason, ModState, Actions} ->
            {stop, Reason, MkState(ModState), [{send_fn, SendFun} | Actions]}
    end;
handle_info({init_mod, Opts=#{ ip := IP, port := Port }}, State=#state{kind=client}) ->
    ConnectTimeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    UniqueSession = maps:get(unique_session, Opts, false),
    HasFromPort = maps:is_key(from_port, Opts),
    BaseOpts = [binary,
                {nodelay, true},
                {active, false},
                {packet, raw}],
    AddrOpts = case libp2p_transport_tcp:ip_addr_type(IP) == inet of
                      true ->
                       %% TODO: ipv6 address and port reuse is not quite implemented yet
                       [inet] ++
                           [{reuseaddr, true} || not UniqueSession] ++
                           [libp2p_transport_tcp:reuseport_raw_option() || not UniqueSession andalso HasFromPort] ++
                           [{port, maps:get(from_port, Opts)} || not UniqueSession, HasFromPort];
                   false ->
                       [inet6, {ipv6_v6only, true}]
               end,
    case gen_tcp:connect(IP, Port, BaseOpts ++ AddrOpts, ConnectTimeout) of
        {ok, Socket} ->
            handle_info({init_mod, Opts#{socket => Socket}}, State);
        {error, Error} ->
            maybe_notify_connect_hanler({error, Error}, Opts),
            {stop, {error, Error}, State}
    end;

handle_info({init_mod, Opts=#{ addr := Addr }}, State=#state{kind=client}) ->
    case libp2p_transport_tcp:from_multiaddr(Addr) of
        {ok, {IP, Port}} ->
            handle_info({init_mod, maps:remove(addr, Opts#{ ip => IP, port => Port})}, State);
        {error, Error} ->
            maybe_notify_connect_hanler({error, Error}, Opts),
            {stop, {error, Error}, State}
    end;
handle_info({tcp, Sock, Incoming}, State=#state{socket=Sock}) ->
    {noreply, State, {continue, {packet, Incoming}}};
handle_info({tcp_closed, Sock}, State=#state{socket=Sock}) ->
    {stop, normal, State};
handle_info({'EXIT', Sock, Reason}, State=#state{socket=Sock}) ->
    {stop, Reason, State};
handle_info({'DOWN', MRef, port, _, _}, State=#state{listen_socket_monitor=MRef}) ->
    lager:debug("Listen socket closed, shutting down"),
    %% TODO: Should we try to receive any remaining data and send
    %% outbound data before actually shutting down? For now this works
    {stop, normal, State};
handle_info({swap_stop, Reason}, State) ->
    {stop, Reason, State};
handle_info(Msg, State=#state{mod=Mod, kind=Kind}) ->
    case erlang:function_exported(Mod, handle_info, 3) of
        true->
            Result = Mod:handle_info(Kind, Msg, State#state.mod_state),
            handle_info_result(Result, State, []);
        false ->
            lager:warning("Unhandled ~p callback info: ~p", [Kind, Msg]),
            {noreply, State}
    end.

handle_packet(Header, Packet, State=#state{mod=Mod}) ->
    Active = case State#state.active of
                 once -> false;
                 true -> true
             end,
    Result = Mod:handle_packet(State#state.kind, Header, Packet, State#state.mod_state),
    handle_info_result(Result, State#state{}, [{active, Active}]).

-spec handle_info_result(libp2p_stream:handle_info_result(), #state{}, libp2p_stream:actions()) ->
                                libp2p_stream_transport:handle_info_result().
handle_info_result({noreply, ModState}, State=#state{}, PreActions) ->
    handle_info_result({noreply, ModState, []}, State, PreActions);
handle_info_result({noreply, ModState, Actions}, State=#state{}, PreActions) ->
    {noreply, State#state{mod_state=ModState}, PreActions ++ Actions};
handle_info_result({stop, Reason, ModState}, State=#state{}, PreActions) ->
    handle_info_result({stop, Reason, ModState, []}, State, PreActions);
handle_info_result({stop, Reason, ModState, Actions}, State=#state{}, PreActions) ->
    {stop, Reason, State#state{mod_state=ModState}, PreActions ++ Actions};
handle_info_result(Other, State=#state{}, _PreActions) ->
    {stop, {error, {invalid_handle_info_result, Other}}, State}.


terminate(_Reason, State=#state{socket=Socket}) ->
    case Socket of
        undefined ->
            ok;
        _ ->
            gen_tcp:close(State#state.socket)
    end.


-spec handle_action(libp2p_stream:action(), #state{}) ->
                           libp2p_stream_transport:handle_action_result().
handle_action({active, Active}, State=#state{}) ->
    %% Avoid calling setopts many times for the same active value.
    SetSocketActive = fun(V) when V == State#state.socket_active ->
                              V;
                         (V) ->
                              ok = inet:setopts(State#state.socket, [{active, V}]),
                              V
                      end,
    case Active of
        true ->
            %% Active true means we continue to deliver to our
            %% callback.  Tell the underlying transport to be in true
            %% mode to deliver packets until we tell it otherwise.
            {action, {active, true}, State#state{active=Active,
                                                 socket_active=SetSocketActive(true)}};
        once ->
            %% Active once meands we're only delivering one of _our_
            %% packets up to the next layer.  Tell the underlying
            %% transport to be in true mode since we may need more
            %% than one of their packets to make one of ours.
            {action, {active, true}, State#state{active=Active,
                                                 socket_active=SetSocketActive(true)}};
        false ->
            %% Turn of active mode for at this layer means turning it
            %% off all the way down.
            ok = inet:setopts(State#state.socket, [{active, false}]),
            {action, {active, false}, State#state{active=Active,
                                                 socket_active=SetSocketActive(false)}}
    end;
handle_action(swap_kind, State=#state{kind=server}) ->
    libp2p_stream_transport:stream_stack_update(State#state.mod, client),
    {ok, State#state{kind=client}};
handle_action(swap_kind, State=#state{kind=client}) ->
    libp2p_stream_transport:stream_stack_update(State#state.mod, server),
    {ok, State#state{kind=server}};
handle_action({swap, Mod, ModOpts}, State=#state{}) ->
    %% In a swap we ignore any furhter actions in the action list and
    libp2p_stream_transport:stream_stack_replace(State#state.mod, Mod, State#state.kind),
    case Mod:init(State#state.kind, maps:merge(ModOpts, State#state.mod_base_opts)) of
        {ok, ModState, Actions} ->
            {replace, Actions, State#state{mod_state=ModState, mod=Mod}};
        {stop, Reason} ->
            self() ! {swap_stop, Reason},
            {ok, State};
        {stop, Reason, ModState, Actions} ->
            self() ! {swap_stop, Reason},
            {replace, Actions, State#state{mod_state=ModState, mod=Mod}}
    end;
handle_action(Action, State) ->
    {action, Action, State}.

%%
%% Utilities
%%

maybe_notify_connect_hanler(Notice, Opts) ->
    case maps:get(stream_handler, Opts, undefined) of
        undefined -> ok;
        {Handler, HandlerState} ->
            Handler ! {stream_error, HandlerState, Notice}
    end.

mk_send_fn(Sock) ->
    fun(Data) ->
            gen_tcp:send(Sock, Data)
    end.
