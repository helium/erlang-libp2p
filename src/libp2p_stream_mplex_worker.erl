-module(libp2p_stream_mplex_worker).

-behavior(libp2p_stream_transport).

%% API
-export([start_link/2,
         command/2,
         reset/1,
         close/1]).

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

command(Pid, Cmd) ->
    gen_server:call(Pid, Cmd, infinity).

-spec reset(pid()) -> ok.
reset(Pid) ->
    gen_server:cast(Pid, reset).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:cast(Pid, close).

%% libp2p_stream_mplex

-spec handle_close(pid) -> ok.
handle_close(Pid) ->
    gen_server:cast(Pid, handle_close).

-spec handle_reset(pid()) -> ok.
handle_reset(Pid) ->
    gen_server:cast(Pid, handle_reset).


start_link(Kind, Opts=#{send_fn := _SendFun}) ->
    libp2p_stream_transport:start_link(?MODULE, Kind, Opts).

init(Kind, Opts=#{stream_id := StreamID, mod := Mod}) ->
    erlang:put(stream_type, {Kind, Mod}),
    ModOpts = maps:get(mod_opts, Opts, #{}),
    case Mod:init(Kind, ModOpts) of
        {ok, ModState, Actions} ->
            {ok, #state{mod=Mod, stream_id=StreamID, mod_state=ModState, kind=Kind}, Actions};
        {close, Reason} ->
            {stop, Reason};
        {close, Reason, Actions} ->
            {stop, Reason, Actions}
    end;
init(Kind, Opts=#{handlers := Handlers, stream_id := _StreamID}) ->
    init(Kind, Opts#{mod => libp2p_multistream,
                     mod_opts => #{ handlers => Handlers }
                    }).

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
    {repy, Reply, State#state{mod_state=ModState}, Actions};
handle_command_result({noreply, ModState}, State=#state{}) ->
    handle_command_result({noreply, ModState, []}, State);
handle_command_result({noreply, ModState, Actions}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}, Actions}.


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
    self() ! {packet, <<>>},
    {noreply, State#state{close_state=read}};

handle_cast(reset, State=#state{}) ->
    %% reset command. Dispatch the reset and close this stream
    {stop, normal, State, [{send, reset}]};
handle_cast(close, State=#state{close_state=read}) ->
    %% Closes _this_ side of the stream for writing and the
    %% remote side for reading. If this side was already remotely
    %% closed we can stop the stream since neither side can read or
    %% write.
    {stop, normal, State, [{send, close}]};
handle_cast(close, State=#state{close_state=write}) ->
    %% ignore multiple close commandds
    {noreply, State};
handle_cast(close, State=#state{}) ->
    %% This closes _this_ side of the stream for writing and the
    %% remote side for reading
    Packet = libp2p_stream_mplex:encode_packet(State#state.stream_id, State#state.kind, close),
    {noreply, State#state{close_state=write}, [{send, Packet}]};

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


handle_info({packet, _Incoming}, State=#state{close_state=read}) ->
    %% Ignore incoming data when the read side is closed
    {noreply, State};
handle_info(Msg, State=#state{mod=Mod}) ->
    case erlang:function_exported(Mod, handle_info, 3) of
        true->
            Result = Mod:handle_info(State#state.kind, Msg, State#state.mod_state),
            handle_info_result(Result, State);
        false ->
            lager:warning("Unhandled callback info: ~p", [Msg]),
            {noreply, State}
    end.

handle_packet(Header, Packet, State=#state{mod=Mod}) ->
    Active = case State#state.active of
                 once -> false;
                 true -> true
             end,
    Result = Mod:handle_packet(Header, Packet, State#state.mod_state),
    handle_info_result(Result, State#state{active=Active}).

-spec handle_info_result(libp2p_stream:handle_info_result(), #state{}) ->
                                libp2p_stream_transport:handle_info_result().
handle_info_result({ok, ModState}, State=#state{}) ->
    handle_info_result({ok, ModState, []}, State);
handle_info_result({ok, ModState, Actions}, State=#state{}) ->
    {noreply, State#state{mod_state=ModState}, Actions};
handle_info_result({close, Reason, ModState}, State=#state{}) ->
    handle_info_result({close, Reason, ModState, []}, State);
handle_info_result({close, Reason, ModState, Actions}, State=#state{}) ->
    {stop, Reason, State#state{mod_state=ModState}, Actions}.

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
    {ok, State#state{active=Active}};
handle_action(swap_kind, State=#state{kind=server}) ->
    erlang:put(stream_type, {client, State#state.mod}),
    {ok, State#state{kind=client}};
handle_action(swap_kind, State=#state{kind=client}) ->
    erlang:put(stream_type, {server, State#state.mod}),
    {ok, State#state{kind=server}};
handle_action([{swap, Mod, ModOpts}], State=#state{}) ->
    %% In a swap we ignore any furhter actions in the action list
    erlang:put(stream_type, {State#state.kind, Mod}),
    case Mod:init(State#state.kind, ModOpts) of
        {ok, ModState, Actions} ->
            {replace, Actions, State#state{mod_state=ModState, mod=Mod}};
        {close, Reason} ->
            self() ! {stop, Reason},
            {ok, State};
        {close, Reason, Actions} ->
            self() ! {stop, Reason},
            {replace, Actions, State}
    end;
handle_action(Action, State) ->
    {action, Action, State}.



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

pdict_test() ->
    %% test kind and mod after start

    %% test kind and mod after swap_kind

    %% test kind and mod after swap
    ok.


-endif.
