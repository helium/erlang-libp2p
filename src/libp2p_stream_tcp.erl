-module(libp2p_stream_tcp).

-behavior(libp2p_stream_transport).

-type opts() :: #{socket => gen_tcp:socket(),
                  mod => atom(),
                  send_fn => libp2p_stream_transport:send_fn()
                 }.

-export_type([opts/0]).

%%% libp2p_stream_transport
-export([start_link/2,
         init/2,
         handle_call/3,
         handle_info/2,
         handle_packet/3,
         handle_action/2,
         terminate/2]).

%% API
-export([command/2]).

-record(state, {
                kind :: libp2p_stream:kind(),
                active=false :: libp2p_stream:active(),
                socket :: gen_tcp:socket(),
                socket_active=false :: libp2p_stream:active(),
                mod :: atom(),
                mod_state :: any(),
                data= <<>> :: binary()
               }).

command(Pid, Cmd) ->
    gen_server:call(Pid, Cmd, infinity).


start_link(Kind, Opts=#{socket := _Sock, send_fn := _SendFun}) ->
    libp2p_stream_transport:start_link(?MODULE, Kind, Opts);
start_link(Kind, Opts=#{socket := Sock}) ->
    SendFun = fun(Data) ->
                      gen_tcp:send(Sock, Data)
              end,
    start_link(Kind, Opts#{send_fn => SendFun}).

-spec init(libp2p_stream:kind(), Opts::opts()) -> libp2p_stream_transport:init_result().
init(Kind, Opts=#{socket := Sock, mod := Mod, send_fn := SendFun}) ->
    erlang:process_flag(trap_exit, true),
    libp2p_stream_transport:stream_stack_update(Mod, Kind),
    case Kind of
        server -> ok;
        client ->
            ok = inet:setopts(Sock, [binary,
                                     {nodelay, true},
                                     {active, false},
                                     {packet, raw}])
    end,
    ModOpts = maps:get(mod_opts, Opts, #{}),
    case Mod:init(Kind, ModOpts#{send_fn => SendFun}) of
        {ok, ModState, Actions} ->
            {ok, #state{mod=Mod, socket=Sock, mod_state=ModState, kind=Kind}, Actions};
        {stop, Reason} ->
            {stop, Reason};
        {stop, Reason, ModState, Actions} ->
            {stop, Reason, #state{mod=Mod, socket=Sock, mod_state=ModState, kind=Kind}, Actions}
    end.

handle_call(Cmd, From, State=#state{mod=Mod, mod_state=ModState}) ->
    case erlang:function_exported(Mod, handle_command, 4) of
        true->
            Result = Mod:handle_command(State#state.kind, Cmd, From, ModState),
            handle_command_result(Result, State);
        false ->
            lager:warning("Unhandled callback call: ~p", [Cmd]),
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


handle_info({tcp, Sock, Incoming}, State=#state{socket=Sock}) ->
    {noreply, State, {continue, {packet, Incoming}}};
handle_info({tcp_closed, Sock}, State=#state{socket=Sock}) ->
    {stop, normal, State};
handle_info({'EXIT', Sock, Reason}, State=#state{socket=Sock}) ->
    {stop, Reason, State};
handle_info({swap_stop, Reason}, State) ->
    {stop, Reason, State};
handle_info(Msg, State=#state{mod=Mod}) ->
    case erlang:function_exported(Mod, handle_info, 3) of
        true->
            Result = Mod:handle_info(State#state.kind, Msg, State#state.mod_state),
            handle_info_result(Result, State, []);
        false ->
            lager:warning("Unhandled callback info: ~p", [Msg]),
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


terminate(_Reason, State=#state{}) ->
    gen_tcp:close(State#state.socket).


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
    case Mod:init(State#state.kind, ModOpts) of
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
