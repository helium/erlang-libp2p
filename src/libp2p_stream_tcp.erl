-module(libp2p_stream_tcp).

-behavior(gen_server).

-type opts() :: #{socket => gen_tcp:socket(),
                  module => atom(),
                  module_opts => any()
                 }.

-export_type([opts/0]).

-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
                kind :: libp2p_stream:kind(),
                socket :: gen_tcp:socket(),
                send_pid :: pid(),
                packet_spec=undefined :: libp2p_packet:spec() | undefined,
                active=once :: libp2p_stream:active(),
                timers=#{} :: #{Key::term() => Timer::reference()},
                mod :: atom(),
                mod_state :: any(),
                data= <<>> :: binary()
               }).


start_link(Kind, Opts) ->
    gen_server:start_link(?MODULE, {Kind, Opts}, []).

init({Kind, #{module := Mod, module_opts := ModOpts, socket := Sock}}) ->
    ok = inet:setopts(Sock, [binary, {active, once}, {packet, raw}]),
    SendPid = spawn_link(mk_async_sender(Sock)),
    State = #state{kind=Kind, mod=Mod, socket=Sock, send_pid=SendPid},
    case Mod:init(Kind, ModOpts) of
        {ok, ModState, Actions} ->
            case proplists:is_defined(packet_spec, Actions) of
                false ->
                    {stop, {error, missing_packet_spec}};
                true ->
                    {ok, handle_actions(Actions, State#state{mod_state=ModState})}
            end;
        {close, Reason} ->
            {stop, Reason};
        {close, Reason, Actions} ->
            handle_actions(Actions, State),
            {stop, Reason}
    end.


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
            Result = Mod:handle_error(State#state.kind, {timeout, Key}, ModState),
            handle_packet_result(Result, State#state{timers=NewTimers})
    end;
handle_info({send_error, Error}, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_error(State#state.kind, Error, ModState),
    handle_packet_result(Result, State);
handle_info({tcp, Sock, Incoming}, State=#state{socket=Sock, data=Data, mod=Mod, mod_state=ModState}) ->
    NewData = <<Data/binary, Incoming/binary>>,
    case libp2p_packet:decode_packet(State#state.packet_spec, NewData) of
        {ok, Header, Data, Tail} ->
            %% Handle the decoded packet
            Result = Mod:handle_packet(State#state.kind, <<Header/binary, Data/binary>>, ModState),
            %% Dispatch the result of handling the packet and try
            %% receiving again since we may have received enough for
            %% multiple packets.
            case handle_packet_result(Result, State#state{data=Tail}) of
                {noreply, NewState} ->
                    handle_info({tcp, Sock, <<>>}, NewState);
                {stop, Reason, NewState} ->
                    {stop, Reason, NewState}
            end;
        {more, _} ->
            inet:setopts(Sock, [{active, once}]),
            {noreply, State#state{data=NewData}}
    end;
handle_info({tcp_closed, Sock}, State=#state{socket=Sock}) ->
    {stop, normal, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.


-spec handle_packet_result(libp2p_stream:handle_packet_result(), #state{}) ->
                                  {noreply, #state{}} |
                                  {stop, term(), #state{}}.
handle_packet_result({ok, ModState}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}};
handle_packet_result({ok, ModState, Actions}, State=#state{}) ->
    {noreply, handle_actions(Actions, State#state{mod_state=ModState})};
handle_packet_result({close, Reason, ModState}, State=#state{}) ->
    {stop, Reason, State#state{mod_state=ModState}};
handle_packet_result({close, Reason, ModState, Actions}, State=#state{}) ->
    {stop, Reason, handle_actions(Actions, State#state{mod_state=ModState})}.


-spec handle_actions(libp2p_stream:actions(), #state{}) -> #state{}.
handle_actions([], State) ->
    State;
handle_actions([{send, Data} | Tail], State=#state{send_pid=SendPid}) ->
    SendPid ! {send, Data},
    handle_actions(Tail, State);
handle_actions([{swap, Mod, ModState} | Tail], State=#state{}) ->
    handle_actions(Tail, State#state{mod=Mod, mod_state=ModState});
handle_actions([{packet_spec, Spec} | Tail], State=#state{}) ->
    %% TOOD: Deal with packet_spec change
    handle_actions(Tail, State#state{packet_spec=Spec});
handle_actions([{active, Active} | Tail], State=#state{}) ->
    %% TODO: deal with active
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



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").




-endif.
