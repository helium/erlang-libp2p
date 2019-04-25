-module(libp2p_stream_tcp).

-behavior(libp2p_stream_transport).

-type opts() :: #{socket => gen_tcp:socket(),
                  handlers => libp2p_stream:handlers(),
                  mod => atom(),
                  mod_opts => any()
                 }.

-export_type([opts/0]).

%%% libp2p_stream_transport
-export([start_link/2,
         init/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         handle_packet/3,
         handle_action/2,
         handle_terminate/2]).

%% API
-export([command/2]).
%% libp2p_stream_transport
-export([transport_setopts/2, transport_send/2, transport_close/2]).

-record(state, {
                kind :: libp2p_stream:kind(),
                active=false :: libp2p_stream:active(),
                socket :: gen_tcp:socket(),
                mod :: atom(),
                mod_state :: any(),
                data= <<>> :: binary()
               }).

command(Pid, Cmd) ->
    gen_server:call(Pid, Cmd, infinity).

%% libp2p_stream_transport

transport_setopts(Sock, Opts) ->
    inet:setopts(Sock, Opts).

transport_send(Sock, Data) ->
    gen_tcp:send(Sock, Data).

transport_close(Sock, _Reason) ->
    gen_tcp:close(Sock).


start_link(Kind, Opts) ->
    libp2p_stream_transport:start_link(?MODULE, Kind, Opts).

-spec init(libp2p_stream:kind(), Opts::opts()) -> libp2p_stream_transport:init_result().
init(Kind, #{socket := Sock, mod := Mod, mod_opts := ModOpts}) ->
    ok = transport_setopts(Sock, [binary, {packet, raw}, {nodelay, true}]),
    case Mod:init(Kind, ModOpts) of
        {ok, ModState, Actions} ->
            {ok, #state{mod=Mod, socket=Sock, mod_state=ModState, kind=Kind}, Actions};
        {close, Reason} ->
            {stop, Reason};
        {close, Reason, Actions} ->
            {stop, Reason, Actions}
    end;
init(Kind, Opts=#{handlers := Handlers, socket := _Sock}) ->
    init(Kind, Opts#{mod => libp2p_multistream,
                     mod_opts => #{ handlers => Handlers }
                     }).

handle_call(Cmd, From, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_command(State#state.kind, Cmd, From, ModState),
    handle_command_result(Result, State).

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


handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({tcp, Sock, Incoming}, State=#state{socket=Sock}) ->
    {noreply, State, {continue, {packet, Incoming}}};
handle_info({tcp_closed, _Sock}, State) ->
    {stop, normal, State};
handle_info(Msg, State=#state{mod=Mod, mod_state=ModState}) ->
    Result = Mod:handle_info(State#state.kind, Msg, ModState),
    handle_info_result(Result, State).

handle_packet(Header, Packet, State=#state{mod=Mod}) ->
    Active = case State#state.active of
                 once -> false; %% Need a way to send a {transport_active, false} action
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

handle_terminate(_Reason, #state{socket=Sock}) ->
    gen_tcp:close(Sock).

-spec handle_action(libp2p_stream:action(), #state{}) ->
                           libp2p_stream_transport:handle_action_result().
handle_action({active, Active}, State=#state{active=Active}) ->
    {ok, State};
handle_action({active, Active}, State=#state{}) ->
    case Active == true orelse Active == once of
        true -> inet:setopts(State#state.socket, [{active, once}]);
        false -> ok
    end,
    {ok, State#state{active=Active}};
handle_action(swap_kind, State=#state{kind=server}) ->
    {ok, State#state{kind=client}};
handle_action(swap_kind, State=#state{kind=client}) ->
    {ok, State#state{kind=server}};
handle_action([{swap, Mod, ModOpts}], State=#state{mod=Mod}) ->
    %% In a swap we ignore any furhter actions in the action list and
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
