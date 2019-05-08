-module(libp2p_stream_transport).

-behavior(gen_server).

-type init_result() ::
        {ok, State::any(), libp2p_stream:actions()} |
        {stop, Reason::term()} |
        {stop, Reason::term(), State::any(), libp2p_stream:actions()}.
-type handle_call_result() ::
        {reply, Reply::term(), NewState::any()} |
        {reply, Reply::term(), NewState::any(), {continue, Continue::term()}} |
        {reply, Reply::term(), NewState::any(), libp2p_stream:actions()} |
        {noreply, NewState::any()} |
        {noreply, NewState::any(), {continue, Continue::term()}} |
        {noreply, NewState::any(), libp2p_stream:actions()} |
        {stop, Reason::any(), NewState::any()} |
        {stop, Reason::any(), NewState::any(), libp2p_stream:actions()}.
-type handle_cast_result() ::
        {noreply, NewState::any()} |
        {noreply, NewState::any(), {continue, Continue::term()}} |
        {noreply, NewState::any(), libp2p_stream:actions()} |
        {stop, Reason::any(), NewState::any()} |
        {stop, Reason::any(), NewState::any(), libp2p_stream:actions()}.
-type handle_info_result() ::
        {noreply, NewState::any()} |
        {noreply, NewState::any(), {continue, Continue::term()}} |
        {noreply, NewState::any(), libp2p_stream:actions()} |
        {stop, Reason::any(), NewState::any()} |
        {stop, Reason::any(), NewState::any(), libp2p_stream:actions()}.
-type handle_continue_result() :: handle_info_result().
-type handle_packet_result() :: handle_info_result().
-type handle_action_result() ::
        {ok, NewState::any()} |
        {action, libp2p_stream:action(), NewState::any()} |
        {replace, libp2p_stream:actions(), NewState::any()}.
-export_type([init_result/0,
              handle_call_result/0,
              handle_cast_result/0,
              handle_info_result/0,
              handle_continue_result/0,
              handle_action_result/0]).

-callback init(libp2p_stream:kind(), Opts::map()) -> init_result().
-callback handle_call(Msg::term(), From::term(), State::any()) -> handle_call_result().
-callback handle_cast(Msg::term(), State::any()) -> handle_cast_result().
-callback handle_info(Msg::term(), State::any()) -> handle_info_result().
-callback handle_continue(Msg::term(), State::any()) -> handle_continue_result().
-callback handle_action(libp2p_stream:action(), State::any()) -> handle_action_result().
-callback handle_packet(libp2p_packet:header(), Data::binary(), State::any()) -> handle_packet_result().
-callback terminate(Reason::any(), State::any()) -> any().

-optional_callbacks([handle_cast/2, handle_continue/2, terminate/2]).

-type send_fn() :: fun((binary()) -> ok).
-export_type([send_fn/0]).

%% API
-export([start_link/3,
         command/2,
         %% in-stream APIs
         stream_stack_update/2,
         stream_stack_replace/3,
         stream_addr_info/0,
         stream_addr_info_update/1
         ]).
%% gen_server
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         handle_continue/2,
         terminate/2]).

-record(state, {
                send_pid :: pid(),
                %% packet_spec is used on receive only
                packet_spec=undefined :: libp2p_packet:spec() | undefined,
                active=false :: libp2p_stream:active(),
                timers=#{} :: #{Key::term() => Timer::reference()},
                mod :: atom(),
                mod_state :: any(),
                data= <<>> :: binary()
               }).

%% The time to wait for the async sender to stop gracefully before
%% allowing the callback module to to terrible things with the
%% underlying sending socket (like closing it). This avoids the
%% callback module closing the socket before the async sender has a
%% chance to flush its final queue of sends.
%%
%% Note this does _not_ guarantee that any number of sends that are
%% specified when the stop action is handled are delivered to the
%% underlying socket before termination may close it.
-define(ASYNC_SENDER_STOP_TIMEOUT, 500).

start_link(Module, Kind, Opts) ->
    gen_server:start_link(?MODULE, {Module, Kind, Opts}, []).


command(Pid, Cmd) ->
    gen_server:call(Pid, Cmd, infinity).

%%
%% API for use inside streams
%%

stream_stack_update(Mod, NewKind) ->
    Stack = lists:keystore(Mod, 1, stream_stack_get(), {Mod, NewKind}),
    stream_stack_put(Stack).

stream_stack_replace(Mod, NewMod, NewKind) ->
    Stack = lists:keyreplace(Mod, 1, stream_stack_get(), {NewMod, NewKind}),
    stream_stack_put(Stack).

stream_addr_info() ->
    erlang:get(stream_addr_info).

stream_addr_info_update({LocalAddr, RemoteAddr}) when is_list(LocalAddr), is_list(RemoteAddr) ->
    erlang:put(stream_addr_info, {LocalAddr, RemoteAddr}).

-spec init({atom(), libp2p_stream:kind(), Opts::map()}) -> {stop, Reason::any()} |
                                                           {ok, #state{}}.
init({Mod, Kind, Opts=#{send_fn := SendFun}}) ->
    stream_stack_update(Mod, Kind),
    SendPid = spawn_link(mk_async_sender(SendFun)),
    State = #state{mod=Mod, mod_state=undefined, send_pid=SendPid},
    Result = Mod:init(Kind, Opts),
    handle_init_result(Result, State).

-spec handle_init_result(init_result(), #state{}) -> {stop, Reason::any()} | {ok, #state{}}.
handle_init_result({ok, ModState, Actions}, State=#state{}) when is_list(Actions) ->
    case proplists:is_defined(packet_spec, Actions) of
        false ->
            handle_init_result({stop, {error, missing_packet_spec}}, State);
        true ->
            {ok, handle_actions(Actions, State#state{mod_state=ModState})}
    end;
handle_init_result({stop, Reason}, #state{}) ->
    {stop, Reason};
handle_init_result({stop, Reason, ModState, Actions}, State=#state{}) ->
    handle_actions(Actions, State#state{mod_state=ModState}),
    {stop, Reason};
handle_init_result(Result, #state{}) ->
    {stop, {invalid_init_result, Result}}.


-spec handle_call(Cmd::term(), From::term(), #state{}) -> {reply, any(), #state{}} |
                                                          {noreply, #state{}}.
handle_call(Cmd, From, State=#state{mod=Mod}) ->
    Result = Mod:handle_call(Cmd, From, State#state.mod_state),
    handle_call_result(Result, State).


-spec handle_call_result(handle_call_result(), #state{}) ->
                                {reply, Reply::term(), #state{}} |
                                {reply, Reply::term(), #state{}, {continue, Continue::term()}} |
                                {noreply, #state{}} |
                                {noreply, #state{}, {continue, Continue::term()}} |
                                {stop, Reason::term(), #state{}}.
handle_call_result({reply, Reply, ModState, {continue, Continue}}, State=#state{}) ->
    {reply, Reply, State#state{mod_state=ModState}, {continue, Continue}};
handle_call_result({reply, Reply, ModState}, State=#state{}) ->
    handle_call_result({reply, Reply, ModState, []}, State);
handle_call_result({reply, Reply, ModState, Actions}, State=#state{}) ->
    {reply, Reply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_call_result({noreply, ModState, {continue, Continue}}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}, {continue, Continue}};
handle_call_result({noreply, ModState}, State=#state{}) ->
    handle_call_result({noreply, ModState, []}, State);
handle_call_result({noreply, ModState, Actions}, State=#state{}) ->
    {noreply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_call_result({stop, Reason, ModState}, State=#state{}) ->
    handle_call_result({stop, Reason, ModState, []}, State);
handle_call_result({stop, Reason, ModState, Actions}, State=#state{}) ->
    {stop, Reason, handle_actions(Actions, State#state{mod_state=ModState})}.


-spec handle_cast(Msg::term(), State::#state{}) -> {noreply, #state{}} |
                                                   {stop, Reason::term(), #state{}}.
handle_cast(Msg, State=#state{mod=Mod}) ->
    case erlang:function_exported(Mod, handle_cast, 2) of
        true->
            Result = Mod:handle_cast(Msg, State#state.mod_state),
            handle_cast_result(Result, State);
        false ->
            lager:warning("Unhandled cast: ~p", [Msg]),
            {noreply, State}
    end.

-spec handle_cast_result(handle_cast_result(), #state{}) ->
                                {noreply, #state{}} |
                                {noreply, #state{}, {continue, Continue::term()}} |
                                {stop, Reason::term(), #state{}}.
handle_cast_result({noreply, ModState, {continue, Continue}}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}, {continue, Continue}};
handle_cast_result({noreply, ModState}, State=#state{}) ->
    handle_cast_result({noreply, ModState, []}, State);
handle_cast_result({noreply, ModState, Actions}, State=#state{}) ->
    {noreply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_cast_result({stop, Reason, ModState}, State=#state{}) ->
    handle_cast_result({stop, Reason, ModState, []}, State);
handle_cast_result({stop, Reason, ModState, Actions}, State=#state{}) ->
    {stop, Reason, handle_actions(Actions, State#state{mod_state=ModState})}.

-spec handle_info(Msg::term(), State::#state{}) ->
                         {noreply, #state{}} |
                         {noreply, #state{}, {continue, Continue::term()}} |
                         {stop, Reason::term(), #state{}}.
handle_info({timeout, Key}, State=#state{timers=Timers, mod=Mod}) ->
    case maps:take(Key, Timers) of
        error ->
            {noreply, State};
        {_, NewTimers} ->
            Result = Mod:handle_info({timeout, Key}, State#state.mod_state),
            handle_info_result(Result, State#state{timers=NewTimers})
    end;
handle_info({packet, Incoming}, State=#state{data=Data}) ->
    dispatch_packets(State#state{data= <<Data/binary, Incoming/binary>>});
handle_info({'EXIT', SendPid, Reason}, State=#state{send_pid=SendPid}) ->
    {stop, Reason, State};
handle_info(Msg, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_info(Msg, ModState),
    handle_info_result(Result, State).

-spec handle_info_result(handle_info_result(), #state{}) ->
                                {noreply, #state{}} |
                                {noreply, #state{}, {continue, Continue::term()}} |
                                {stop, Reason::term(), #state{}}.
handle_info_result({noreply, ModState, {continue, Continue}}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}, {continue, Continue}};
handle_info_result({noreply, ModState}, State=#state{}) ->
    handle_info_result({noreply, ModState, []}, State);
handle_info_result({noreply, ModState, Actions}, State=#state{}) ->
    {noreply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_info_result({stop, Reason, ModState}, State=#state{}) ->
    handle_info_result({stop, Reason, ModState, []}, State);
handle_info_result({stop, Reason, ModState, Actions}, State=#state{}) ->
    {stop, Reason, handle_actions(Actions, State#state{mod_state=ModState})}.


handle_continue({packet, Incoming}, State=#state{data=Data}) ->
    dispatch_packets(State#state{data= <<Data/binary, Incoming/binary>>});
handle_continue(Msg, State=#state{mod=Mod}) ->
    case erlang:function_exported(Mod, handle_continue, 2) of
        true->
            Result = Mod:handle_continue(Msg, State#state.mod_state),
            handle_info_result(Result, State);
        false ->
            {noreply, State}
    end.

-spec terminate(Reason::term(), State::#state{}) -> any().
terminate(Reason, State=#state{mod=Mod, send_pid=SendPid}) ->
    SendPid ! stop,
    receive
        sender_stopped -> ok
    after ?ASYNC_SENDER_STOP_TIMEOUT ->
            lager:debug("Async sender may not have sent all data")
    end,
    case erlang:function_exported(Mod, terminate, 2) of
        true -> Mod:terminate(Reason, State#state.mod_state);
        false -> ok
    end.


-spec dispatch_packets(#state{}) -> {noreply, #state{}} |
                                    {noreply, #state{}, {continue, term()}} |
                                    {stop, term(), #state{}}.
dispatch_packets(State=#state{data= <<>>}) ->
    {noreply, State};
dispatch_packets(State=#state{active=false}) ->
    {noreply, State};
dispatch_packets(State=#state{data=Data, mod=Mod}) ->
    case libp2p_packet:decode_packet(State#state.packet_spec, Data) of
        {ok,  Header, Packet, Tail} ->
            Result = Mod:handle_packet(Header, Packet, State#state.mod_state),
            %% Dispatch the result of handling the packet and try
            %% receiving again since we may have received enough for
            %% multiple packets.
            case handle_info_result(Result, State#state{data=Tail}) of
                {noreply, NewState}  ->
                    dispatch_packets(NewState);
                {noreply, NewState, {continue, Continue}}  ->
                    {noreply, NewState, {continue, Continue}};
                {stop, Reason, NewState} ->
                    {stop, Reason, NewState}
            end;
        {more, _N} ->
            {noreply, State}
    end.


-spec handle_actions(libp2p_stream:actions(), #state{}) -> #state{}.
handle_actions([], State=#state{}) ->
    State;
handle_actions([Action | Tail], State=#state{mod=Mod}) ->
    case Mod:handle_action(Action, State#state.mod_state) of
        {ok, ModState} ->
            handle_actions(Tail, State#state{mod_state=ModState});
        {action, NewAction, ModState} ->
            handle_actions(Tail, handle_action(NewAction, State#state{mod_state=ModState}));
        {replace, Actions, ModState} ->
            handle_actions(Actions, State#state{mod_state=ModState})
    end.

-spec handle_action(libp2p_stream:action(), #state{}) -> #state{}.
handle_action({active, Active}, State=#state{active=Active}) ->
    State;
handle_action({active, Active}, State=#state{}) ->
    State#state{active=Active};
handle_action({send, Data}, State=#state{send_pid=SendPid}) ->
    SendPid ! {send, Data},
    State;
handle_action({packet_spec, Spec}, State=#state{packet_spec=Spec}) ->
    %% Do nothing if the spec did not change
    State;
handle_action({packet_spec, Spec}, State=#state{}) ->
    %% Spec is different, dispatch empty data to deliver any existing
    %% data again with the new spec.
    self () ! {packet, <<>>},
    State#state{packet_spec=Spec};
handle_action({reply, To, Reply}, State=#state{}) ->
    gen_server:reply(To, Reply),
    State;
handle_action({timer, Key, Timeout}, State=#state{timers=Timers}) ->
    OldTimer = maps:get(Key, Timers, make_ref()),
    erlang:cancel_timer(OldTimer),
    NewTimer = erlang:send_after(Timeout, self(), {timeout, Key}),
    State#state{timers=maps:put(Key, NewTimer, Timers)};
handle_action({cancel_timer, Key}, State=#state{timers=Timers}) ->
    NewTimers = case maps:take(Key, Timers) of
                    error ->
                        Timers;
                    {Timer, NewMap} ->
                        erlang:cancel_timer(Timer),
                        NewMap
                end,
    State#state{timers=NewTimers};
handle_action(Action, State) ->
    lager:warning("Unhandled action: ~p", [Action]),
    State.

%%
%% Utils
%%

stream_stack_get() ->
    case erlang:get(stream_stack) of
        undefined -> [];
        Other -> Other
    end.

stream_stack_put(Stack) ->
    erlang:put(stream_stack, Stack),
    ok.

mk_async_sender(SendFun) ->
    Parent = self(),
    Sender = fun Fun() ->
                     receive
                         {'DOWN', _, process, Parent, _} ->
                             ok;
                         stop ->
                             Parent ! sender_stopped,
                             ok;
                         {send, Data} ->
                             case SendFun(Data) of
                                 ok ->
                                     ok;
                                 {error, Error} ->
                                     Parent ! {send_error, {error, Error}}
                             end,
                             Fun()
                     end
             end,
    fun() ->
            erlang:monitor(process, Parent),
            Sender()
    end.
