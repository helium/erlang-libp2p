-module(libp2p_stream_mplex_worker).

-behavior(gen_server).

%% API
-export([start_link/2,
         command/2,
         reset/1,
         close/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
%% internal
-export([handle_packet/2, handle_close/1, handle_reset/1]).

-record(state, {
                kind :: libp2p_stream:kind(),
                stream_id :: libp2p_stream_mplex:stream_id(),
                socket :: gen_tcp:socket(),
                send_pid :: pid(),
                close_state=undefined :: read | write | undefined,
                packet_spec=undefined :: libp2p_packet:spec() | undefined,
                active=false :: libp2p_stream:active(),
                timers=#{} :: #{Key::term() => Timer::reference()},
                mod :: atom(),
                mod_state :: any(),
                data= <<>> :: binary()
               }).

%% API

-spec reset(pid()) -> ok.
reset(Pid) ->
    gen_server:cast(Pid, reset).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:cast(Pid, close).

command(Pid, Cmd) ->
    gen_server:call(Pid, Cmd, infinity).

%% Internal API

-spec handle_packet(pid(), binary()) -> ok.
handle_packet(Pid, Data) ->
    Pid ! {packet, Data},
    ok.

-spec handle_close(pid) -> ok.
handle_close(Pid) ->
    gen_server:cast(Pid, handle_close).

-spec handle_reset(pid()) -> ok.
handle_reset(Pid) ->
    gen_server:cast(Pid, handle_reset).


start_link(Kind, Opts) ->
    gen_server:start_link(?MODULE, {Kind, Opts}, []).

init({Kind, #{mod := Mod, mod_opts := ModOpts, stream_id := StreamID, socket := Sock}}) ->
    SendPid = spawn_link(mk_async_sender(Sock)),
    State = #state{kind=Kind, mod=Mod, mod_state=undefined, socket=Sock, stream_id=StreamID, send_pid=SendPid},
    Result = Mod:init(Kind, ModOpts),
    handle_init_result(Result, State);
init({Kind, Opts=#{handlers := Handlers, stream_id := _StreamID, socket := _Sock}}) ->
    init({Kind, Opts#{mod => libp2p_multistream,
                      mod_opts => #{ handlers => Handlers }
                     }}).


handle_call(Cmd, From, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_command(State#state.kind, Cmd, From, ModState),
    handle_command_result(Result, State).

handle_cast(handle_reset, State=#state{}) ->
    %% Received a reset, stop stream
    lager:debug("Resetting stream: ~p", [State#state.stream_id]),
    {stop, normal, State};
handle_cast(handle_close, State=#state{close_state=write}) ->
    %% Received a remote close when we'd already closed this side for
    %% writing. Neither side can read or write, so stop the stream.
    {stop, normal, State};
handle_cast(handle_close, State=#state{}) ->
    %% Received a close. Close this stream for reading, allow writing.
    %% Dispatch all remaining packets
    case dispatch_packets(State) of
        {ok, NewState} ->
            {noreply, NewState#state{close_state=read, data= <<>>}};
        {stop, Reason, NewState} ->
            {stop, Reason, NewState}
    end;


handle_cast(reset, State=#state{}) ->
    %% reset command. Dispatch the reset and close this stream
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, reset),
    {stop, normal, handle_actions([{send, Packet}], State)};

handle_cast(close, State=#state{close_state=read}) ->
    %% Closes _this_ side of the stream for writing and the
    %% remote side for reading. If this side was already remotely
    %% closed we can stop the stream since neither side can read or
    %% write.
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, close),
    {stop, normal, State, [{send, Packet}]};
handle_cast(close, State=#state{close_state=write}) ->
    %% ignore multiple close commandds
    {noreply, State};
handle_cast(close, State=#state{}) ->
    %% This closes _this_ side of the stream for writing and the
    %% remote side for reading
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, close),
    {noreply, State#state{close_state=write},
     [{send, Packet}]};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


handle_info({packet, _Incoming}, State=#state{close_state=read}) ->
    %% Ignore incoming data when the read side is closed
    {noreply, State};
handle_info({packet, Incoming}, State=#state{data=Data}) ->
    case dispatch_packets(State#state{data= <<Data/binary, Incoming/binary>>}) of
        {ok, NewState} ->
            {noreply, NewState};
        {stop, Reason, NewState} ->
            {stop, Reason, NewState}
    end;
handle_info({timeout, Key}, State=#state{timers=Timers, mod=Mod, mod_state=ModState}) ->
    case maps:take(Key, Timers) of
        error ->
            {noreply, State};
        {_, NewTimers} ->
            Result = Mod:handle_info(State#state.kind, {stream_timeout, Key}, ModState),
            handle_packet_result(Result, State#state{timers=NewTimers})
    end;
handle_info({send_error, Error}, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_info(State#state.kind, {stream_error, Error}, ModState),
    handle_packet_result(Result, State);
handle_info({stop, Reason}, State=#state{}) ->
    %% Sent by an action list swap action where the new module decides
    %% it wants to stop
    {stop, Reason, State};
handle_info({'EXIT', SendPid, Reason}, State=#state{send_pid=SendPid}) ->
    {stop, Reason, State};
handle_info(Msg, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_info(State#state.kind, Msg, ModState),
    handle_packet_result(Result, State).


-spec dispatch_packets(#state{}) -> {ok, #state{}} |
                                    {stop, term(), #state{}}.
dispatch_packets(State=#state{active=false}) ->
    {ok, State};
dispatch_packets(State=#state{data=Data, mod=Mod, mod_state=ModState, active=Active}) ->
    case libp2p_packet:decode_packet(State#state.packet_spec, Data) of
        {ok, Header, Packet, Tail} ->
            %% Handle the decoded packet
            Result = Mod:handle_packet(State#state.kind, Header, Packet, ModState),
            NewActive = case Active of
                            once -> false;
                            _ -> Active
                        end,
            %% Dispatch the result of handling the packet and try
            %% receiving again since we may have received enough for
            %% multiple packets.
            case handle_packet_result(Result, State#state{data=Tail, active=NewActive}) of
                {noreply, NewState}  ->
                    dispatch_packets(NewState);
                {stop, Reason, NewState} ->
                    {stop, Reason, NewState}
            end;
        {more, _} ->
            %% Dispatch empty actions to ensure opts are set
            {ok, handle_actions([], State)}
    end.

-spec handle_command_result(libp2p_stream:handle_command_result(), #state{}) ->
                                   {reply, any(), #state{}} |
                                   {noreply, #state{}}.
handle_command_result({reply, Reply, ModState}, State=#state{}) ->
    handle_command_result({reply, Reply, ModState, []}, State);
handle_command_result({reply, Reply, ModState, Actions}, State=#state{}) ->
    {repy, Reply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_command_result({noreply, ModState}, State=#state{}) ->
    handle_command_result({noreply, ModState, []}, State);
handle_command_result({noreply, ModState, Actions}, State=#state{}) ->
    {noreply, handle_actions(Actions, State#state{mod_state=ModState})}.

-spec handle_packet_result(libp2p_stream:handle_packet_result(), #state{}) ->
                                  {noreply, #state{}} |
                                  {stop, term(), #state{}}.
handle_packet_result({ok, ModState}, State=#state{}) ->
    handle_packet_result({ok, ModState, []}, State);
handle_packet_result({ok, ModState, Actions}, State=#state{}) ->
    {noreply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_packet_result({close, Reason, ModState}, State=#state{}) ->
    handle_packet_result({close, Reason, ModState, []}, State);
handle_packet_result({close, Reason, ModState, Actions}, State=#state{}) ->
    {stop, Reason, handle_actions(Actions, State#state{mod_state=ModState})}.


-spec handle_init_result(libp2p_stream:init_result(), #state{}) -> {stop, Reason::any()} | {ok, #state{}}.
handle_init_result({ok, ModState, Actions}, State=#state{})  ->
    case proplists:is_defined(packet_spec, Actions) of
        false ->
            handle_init_result({close, {error, missing_packet_spec}}, State);
        true ->
            {ok, handle_actions(Actions, State#state{mod_state=ModState})}
    end;
handle_init_result({close, Reason}, State=#state{}) ->
    handle_init_result({close, Reason, []}, State);
handle_init_result({close, Reason, Actions}, State=#state{}) ->
    handle_actions(Actions, State),
    {stop, Reason};
handle_init_result(Result, #state{}) ->
    {stop, {invalid_init_result, Result}}.


-spec handle_actions(libp2p_stream:actions(), #state{}) -> #state{}.
handle_actions([], State=#state{}) ->
    State;
handle_actions([{send, _Data} | Tail], State=#state{close_state=write}) ->
    %% Ignore any send actions if we're closed for writing
    handle_actions(Tail, State);
handle_actions([{send, Data} | Tail], State=#state{send_pid=SendPid}) ->
    SendPid ! {send, Data},
    handle_actions(Tail, State);
handle_actions([{swap, Mod, ModOpts} | _], State=#state{}) ->
    %% In a swap we ignore any furhter actions in the action list and
    %% let handle_init_result deal with the actions returned by the
    %% new module
    Result = Mod:init(State#state.kind, ModOpts),
    case handle_init_result(Result, State#state{mod=Mod}) of
        {ok, NewState} ->
            NewState;
        {stop, Reason} ->
            self() ! {stop, Reason},
            State
    end;
handle_actions([{packet_spec, Spec} | Tail], State=#state{packet_spec=Spec}) ->
    %% Do nothing if the spec did not change
    handle_actions(Tail, State);
handle_actions([{packet_spec, Spec} | Tail], State=#state{}) ->
    %% Spec is different, notify the current process so it can decide
    %% it it needs to dispatch more packets under the new spec
    self () ! {packet, <<>>},
    handle_actions(Tail, State#state{packet_spec=Spec});
handle_actions([{active, Active} | Tail], State=#state{}) ->
    handle_actions(Tail, State#state{active=Active});
handle_actions([{reply, To, Reply} | Tail], State=#state{}) ->
    gen_server:reply(To, Reply),
    handle_actions(Tail, State);
handle_actions([{timer, Key, Timeout} | Tail], State=#state{timers=Timers}) ->
    NewTimers = case maps:get(Key, Timers, false) of
                    false ->
                        Timers;
                    Timer ->
                        erlang:cancel_timer(Timer),
                        NewTimer = erlang:send_after(Timeout, self(), {timeout, Key}),
                        maps:put(Key, NewTimer, Timers)
                end,
    handle_actions(Tail, State#state{timers=NewTimers});
handle_actions([{cancel_timer, Key} | Tail], State=#state{timers=Timers}) ->
    NewTimers = case maps:take(Key, Timers) of
                    error ->
                        Timers;
                    {Timer, NewMap} ->
                        erlang:cancel_timer(Timer),
                        NewMap
                end,
    handle_actions(Tail, State#state{timers=NewTimers});
handle_actions([swap_kind | Tail], State=#state{}) ->
    NewKind = case State#state.kind of
                  client -> server;
                  server -> client
              end,
    handle_actions(Tail, State#state{kind=NewKind}).

mk_async_sender(Sock) ->
    Parent = self(),
    Sender = fun Fun() ->
                     receive
                         {'DOWN', _, process, Parent, _} ->
                             ok;
                         {send, Data} ->
                             case gen_tcp:send(Sock, Data) of
                                 ok -> ok;
                                 Error ->
                                     Parent ! {send_error, {error, Error}}
                             end,
                             Fun()
                     end
             end,
    fun() ->
            erlang:monitor(process, Parent),
            Sender()
    end.
