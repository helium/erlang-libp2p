-module(libp2p_group_worker).

-behaviour(gen_statem).

%% API
-export([start_link/4, assign_target/2]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([request_target/3, connect/3]).

-define(SERVER, ?MODULE).

-record(data,
        { tid :: ets:tab(),
          kind :: atom(),
          server :: pid(),
          client_specs :: [libp2p_group:stream_client_spec()],
          target=undefined :: undefined | string(),
          monitor=undefined :: undefined | reference()
        }).

-define(ASSIGN_RETRY, 500).
-define(CONNECT_RETRY, 5000).

%% API

assign_target(Pid, MAddr) ->
    gen_statem:cast(Pid, {assign_target, MAddr}).

%% gen_statem
%%

-spec start_link(atom(), [libp2p_group:stream_client_spec()], pid(), ets:tab()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Kind, ClientSpecs, Server, TID) ->
    gen_statem:start_link(?MODULE, [Kind, ClientSpecs, Server, TID], []).


callback_mode() -> [state_functions, state_enter].

-spec init(Args :: term()) ->
                  gen_statem:init_result(atom()).
init([Kind, ClientSpecs, Server, TID]) ->
    process_flag(trap_exit, true),
    {ok, request_target, #data{tid=TID, server=Server, kind=Kind, client_specs=ClientSpecs}}.

-spec request_target('enter', Msg :: term(), Data :: term()) ->
                            gen_statem:state_enter_result(request_target);
                    (gen_statem:event_type(), Msg :: term(), Data :: term()) ->
                            gen_statem:event_handler_result(atom()).
request_target(enter, _, Data=#data{kind=Kind, server=Server}) ->
    libp2p_group_gossip_server:request_target(Server, Kind, self()),
    {next_state, request_target, Data, ?ASSIGN_RETRY};
request_target(timeout, _, #data{}) ->
    repeat_state_and_data;
request_target(cast, {assign_target, undefined}, #data{}) ->
    repeat_state_and_data;
request_target(cast, {assign_target, MAddr}, Data=#data{}) ->
    {next_state, connect, Data#data{target=MAddr}};
request_target(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec connect('enter', Msg :: term(), Data :: term()) ->
                     gen_statem:state_enter_result(connect);
             (gen_statem:event_type(), Msg :: term(), Data :: term()) ->
                     gen_statem:event_handler_result(atom()).
connect(enter, _, Data=#data{target=Target, tid=TID, client_specs=ClientSpecs}) ->
    case libp2p_transport:connect_to(Target, [], 5000, TID) of
        {error, _Reason} ->
            {keep_state, Data, ?CONNECT_RETRY};
        {ok, ConnAddr, SessionPid} ->
            libp2p_swarm:register_session(libp2p_swarm:swarm(TID), ConnAddr, SessionPid),
            lists:foreach(fun({Path, {M, A}}) ->
                                  libp2p_session:start_client_framed_stream(Path, SessionPid, M, A)
                          end, ClientSpecs),
            {next_state, connect, Data#data{monitor=erlang:monitor(process, SessionPid)}}
    end;
connect(timeout, _, #data{}) ->
    repeat_state_and_data;
connect(info, {'DOWN', Monitor, process, _Pid, _Reason}, Data=#data{monitor=Monitor}) ->
    {keep_state, Data#data{monitor=undefined}, ?CONNECT_RETRY};
connect(cast, {assign_target, undefined}, Data=#data{monitor=Monitor}) ->
    erlang:demonitor(Monitor),
    {next_state, request_target, Data#data{monitor=undefined, target=undefined}};
connect(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec terminate(Reason :: term(), State :: term(), Data :: term()) ->
                       any().
terminate(_Reason, _State, #data{monitor=Monitor}) ->
    case Monitor of
        undefined -> ok;
        _ -> erlang:demonitor(Monitor)
    end.


handle_event(EventType, Msg, #data{}) ->
    lager:warning("Unhandled event ~p: ~p", [EventType, Msg]),
    keep_state_and_data.
