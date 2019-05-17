-module(libp2p_stream_mplex_worker).

-behavior(libp2p_stream_transport).

%% API
-export([start_link/2,
         reset/1,
         close/1,
         close_state/1]).

%% libp2p_stream_transport
-export([init/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         handle_packet/3,
         handle_action/2]).

%% internal
-export([handle_close/1, handle_reset/1]).

-record(state, {
                kind :: libp2p_stream:kind(),
                active=false :: libp2p_stream:active(),
                stream_id :: libp2p_stream_mplex:stream_id(),
                close_state=undefined :: read | write | undefined,
                mod :: atom(),
                mod_state :: any()
               }).

%% API

-spec reset(pid()) -> ok.
reset(Pid) ->
    gen_server:cast(Pid, stream_reset).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:cast(Pid, stream_close).

close_state(Pid) ->
    libp2p_stream_transport:command(Pid, stream_close_state).

%% libp2p_stream_mplex

-spec handle_close(pid) -> ok.
handle_close(Pid) ->
    gen_server:cast(Pid, handle_close).

-spec handle_reset(pid()) -> ok.
handle_reset(Pid) ->
    gen_server:cast(Pid, handle_reset).


start_link(Kind, Opts=#{send_fn := _SendFun}) ->
    libp2p_stream_transport:start_link(?MODULE, Kind, Opts#{}).

init(Kind, Opts=#{stream_id := StreamID, mod := Mod, addr_info := AddrInfo, muxer := Muxer}) ->
    libp2p_stream_transport:stream_stack_update(Mod, Kind),
    libp2p_stream_transport:stream_addr_info_update(AddrInfo),
    libp2p_stream_transport:stream_muxer_update(Muxer),
    ModOpts = maps:get(mod_opts, Opts, #{}),
    MakeState = fun(ModState) ->
                        #state{mod=Mod,
                               stream_id=StreamID,
                               mod_state=ModState,
                               kind=Kind}
                end,
    case Mod:init(Kind, ModOpts) of
        {ok, ModState, Actions} ->
            {ok, MakeState(ModState), Actions};
        {stop, Reason} ->
            {stop, Reason};
        {stop, Reason, ModState, Actions} ->
            {stop, Reason, MakeState(ModState), Actions}
    end.

handle_call(stream_close_state, _From, State=#state{}) ->
    {reply, {ok, State#state.close_state}, State};
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


handle_cast(handle_reset, State=#state{}) ->
    %% Received a reset, stop stream
    lager:debug("Resetting ~p stream: ~p", [State#state.kind, State#state.stream_id]),
    {stop, normal, State};
handle_cast(handle_close, State=#state{close_state=write}) ->
    %% Received a remote close when we'd already closed this side for
    %% writing. Neither side can read or write, so stop the stream.
    {stop, normal, State};
handle_cast(handle_close, State=#state{}) ->
    %% Received a close. Close this stream for reading, allow writing.
    %% Dispatch all remaining packets
    self() ! {packet, <<>>},
    {noreply, State#state{close_state=read}};

handle_cast(stream_reset, State=#state{}) ->
    %% reset command. Dispatch the reset and close this stream
    {stop, normal, State, [{send, reset}]};
handle_cast(stream_close, State=#state{close_state=read}) ->
    %% Closes _this_ side of the stream for writing and the
    %% remote side for reading. If this side was already remotely
    %% closed we can stop the stream since neither side can read or
    %% write.
    {stop, normal, State, [{send, close}]};
handle_cast(stream_close, State=#state{close_state=write}) ->
    %% ignore multiple close commandds
    {noreply, State};
handle_cast(stream_close, State=#state{}) ->
    %% This closes _this_ side of the stream for writing and the
    %% remote side for reading
    {noreply, State#state{close_state=write}, [{send, close}]};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


handle_info({packet, _Incoming}, State=#state{close_state=read}) ->
    %% Ignore incoming data when the read side is closed
    {noreply, State};
handle_info({swap_stop, _, normal}, State) ->
    {stop, normal, State};
handle_info({swap_stop, Mod, Reason}, State) ->
    lager:debug("Stopping after ~p:init error: ~p", [Mod, Reason]),
    {stop, normal, State};
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


handle_action({send, reset}, State=#state{}) ->
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, reset),
    {action, {send, Packet}, State};
handle_action({send, close}, State=#state{}) ->
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, close),
    {action, {send, Packet}, State};
handle_action({send, Data}, State=#state{}) ->
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, msg, Data),
    {action, {send, Packet}, State};
handle_action({active, Active}, State=#state{}) ->
    case Active of
        true ->
            %% Active true means we continue to deliver to our
            %% callback.  Tell the underlying transport to be in true
            %% mode to deliver packets until we tell it otherwise.
            {action, {active, true}, State#state{active=Active}};
        once ->
            %% Active once meands we're only delivering one of _our_
            %% packets up to the next layer.  Tell the underlying
            %% transport to be in true mode since we may need more
            %% than one of their packets to make one of ours.
            {action, {active, true}, State#state{active=Active}};
        false ->
            %% Turn of active mode for at this layer means turning it
            %% off all the way down.
            {action, {active, false}, State#state{active=Active}}
    end;
handle_action(swap_kind, State=#state{kind=server}) ->
    libp2p_stream_transport:stream_stack_update(State#state.mod, client),
    {ok, State#state{kind=client}};
handle_action(swap_kind, State=#state{kind=client}) ->
    libp2p_stream_transport:stream_stack_update(State#state.mod, server),
    {ok, State#state{kind=server}};
handle_action({swap, Mod, ModOpts}, State=#state{}) ->
    %% In a swap we ignore any furhter actions in the action list
    libp2p_stream_transport:stream_stack_replace(State#state.mod, Mod, State#state.kind),
    case Mod:init(State#state.kind, ModOpts) of
        {ok, ModState, Actions} ->
            {replace, Actions, State#state{mod_state=ModState, mod=Mod}};
        {stop, Reason} ->
            self() ! {swap_stop, Mod, Reason},
            {ok, State};
        {stop, Reason, ModState, Actions} ->
            self() ! {swap_stop, Mod, Reason},
            {replace, Actions, State#state{mod_state=ModState}}
    end;
handle_action(Action, State) ->
    {action, Action, State}.
