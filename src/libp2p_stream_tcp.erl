-module(libp2p_stream_tcp).

-behavior(gen_server).

-type opts() :: #{socket => gen_tcp:socket(),
                  mod => atom(),
                  mod_opts => any()
                 }.

-export_type([opts/0]).

%%% gen_server
-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2, handle_terminate/2]).

%% API
-export([command/2]).

-record(state, {
                kind :: libp2p_stream:kind(),
                socket :: gen_tcp:socket(),
                send_pid :: pid(),
                packet_spec=undefined :: libp2p_packet:spec() | undefined,
                active=0 :: libp2p_stream:active(),
                timers=#{} :: #{Key::term() => Timer::reference()},
                mod :: atom(),
                mod_state :: any(),
                data= <<>> :: binary()
               }).

command(Pid, Cmd) ->
    gen_server:call(Pid, Cmd, infinity).

%%

start_link(Kind, Opts) ->
    gen_server:start_link(?MODULE, {Kind, Opts}, []).

init({Kind, #{mod := Mod, mod_opts := ModOpts, socket := Sock}}) ->
    erlang:process_flag(trap_exit, true),
    ok = inet:setopts(Sock, [binary, {packet, raw}, nodelay]),
    SendPid = spawn_link(mk_async_sender(Sock)),
    State = #state{kind=Kind, mod=Mod, mod_state=undefined, socket=Sock, send_pid=SendPid},
    Result = Mod:init(Kind, ModOpts),
    handle_init_result(Result, State).


handle_call(Cmd, From, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_command(State#state.kind, Cmd, From, ModState),
    handle_command_result(Result, State);
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

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
handle_info({tcp, Sock, Incoming}, State=#state{socket=Sock, data=Data}) ->
    case dispatch_packets(State#state{data= <<Data/binary, Incoming/binary>>}) of
        {ok, NewState} ->
            {noreply, NewState};
        {stop, Reason, NewState} ->
            {stop, Reason, NewState}
    end;
handle_info({tcp_closed, Sock}, State=#state{socket=Sock}) ->
    {stop, normal, State};
handle_info({stop, Reason}, State=#state{}) ->
    {stop, Reason, State};
handle_info({'EXIT', SendPid, Reason}, State=#state{send_pid=SendPid}) ->
    {stop, Reason, State};
handle_info(Msg, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_info(State#state.kind, Msg, ModState),
    handle_packet_result(Result, State).

handle_terminate(_Reason, State=#state{}) ->
    gen_tcp:close(State#state.socket).


-spec dispatch_packets(#state{}) -> {ok, #state{}} |
                                    {stop, term(), #state{}}.
dispatch_packets(State=#state{active=0}) ->
    {ok, State};
dispatch_packets(State=#state{data=Data, mod=Mod, mod_state=ModState}) ->
    case libp2p_packet:decode_packet(State#state.packet_spec, Data) of
        {ok, Header, Packet, Tail} ->
            %% Handle the decoded packet
            Result = Mod:handle_packet(State#state.kind, <<Header/binary, Packet/binary>>, ModState),
            NewActive = case State#state.active of
                            once -> 0;
                            N when is_integer(N) -> N - 1
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
            %% Dispatch empty actions to ensure inet opts are set
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
handle_actions([], State) ->
    case State#state.active of
        once ->
            inet:setopts(State#state.socket, [{active, once}]);
        N when is_integer(N) andalso N > 0 ->
            inet:setopts(State#state.socket, [{active, once}]);
        _ -> ok
    end,
    State;
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
    %% Spec is different, dispatch empty data to deliver any existing
    %% data again with the new spec.
    self () ! {tcp, State#state.socket, <<>>},
    handle_actions(Tail, State#state{packet_spec=Spec});
handle_actions([{active, AddActive} | Tail], State=#state{active=Active}) when is_integer(AddActive) ->
    NewActive = case Active of
                    once -> AddActive;
                    N when is_integer(N) -> max(0, N + AddActive)
                end,
    handle_actions(Tail, State#state{active=NewActive});
handle_actions([{active, once} | Tail], State=#state{}) ->
    handle_actions(Tail, State#state{active=once});
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



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


init_test() ->
    meck:new(inet, [unstick, passthrough]),
    meck:expect(inet, setopts, fun(_Sock, _Opts) -> ok end),

    meck:new(test_stream, [non_strict]),
    meck:expect(test_stream, init, fun(_, [Result]) -> Result end),

    %% valid close response causes a stop
    ?assertMatch({stop, test_stream_stop},
                 ?MODULE:init({client, #{socket => -1,
                                         mod => test_stream,
                                         mod_opts => [{close, test_stream_stop}]
                                        }})),

    %% invalid init result causes a stop
    ?assertMatch({stop, {invalid_init_result, invalid_result}},
                 ?MODULE:init({client, #{socket => -1,
                                         mod => test_stream,
                                         mod_opts => [invalid_result]
                                        }})),
    %% missing packet spec, causes a stop
    ?assertMatch({stop, {error, missing_packet_spec}},
                 ?MODULE:init({client, #{socket => -1,
                                         mod => test_stream,
                                         mod_opts => [{ok, {}, []}]
                                        }})),
    %% valid response gets an ok
    ?assertMatch({ok, #state{packet_spec=[u8]}},
                 ?MODULE:init({client, #{socket => -1,
                                         mod => test_stream,
                                         mod_opts => [{ok, {}, [{packet_spec, [u8]}]}]
                                        }})),

    ?assert(meck:validate(test_stream)),
    meck:unload(test_stream),

    meck:unload(inet),
    ok.



-endif.
