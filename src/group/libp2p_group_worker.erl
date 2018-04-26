-module(libp2p_group_worker).

-behaviour(gen_statem).

%% API
-export([start_link/4, assign_target/2, assign_stream/3, assign_session/3, send/3]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([request_target/3, connect/3]).

-define(SERVER, ?MODULE).

-record(data,
        { tid :: ets:tab(),
          kind :: atom(),
          server :: pid(),
          client_spec :: libp2p_group:stream_client_spec(),
          target=undefined :: undefined | string(),
          send_pid=undefined :: undefined | libp2p_connection:connection(),
          connect_pid=undefined :: undefined | pid(),
          session_monitor=undefined :: undefined | reference()
        }).

-define(ASSIGN_RETRY, 500).
-define(CONNECT_RETRY, 1000).

%% API

-spec assign_target(pid(), string() | undefined) -> ok.
assign_target(Pid, MAddr) ->
    gen_statem:cast(Pid, {assign_target, MAddr}).

assign_stream(Pid, MAddr, Connection) ->
    gen_statem:cast(Pid, {assign_stream, MAddr, Connection}).

assign_session(Pid, MAddr, SessionPid) ->
    gen_statem:cast(Pid, {assign_session, MAddr, SessionPid}).

-spec send(pid(), term(), binary()) -> ok.
send(Pid, Ref, Data) ->
    gen_statem:cast(Pid, {send, Ref, Data}).


%% gen_statem
%%

-spec start_link(atom(), libp2p_group:stream_client_spec(), pid(), ets:tab()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Kind, ClientSpec, Server, TID) ->
    gen_statem:start_link(?MODULE, [Kind, ClientSpec, Server, TID], []).


callback_mode() -> [state_functions, state_enter].

-spec init(Args :: term()) -> gen_statem:init_result(atom()).
init([Kind, ClientSpec, Server, TID]) ->
    process_flag(trap_exit, true),
    {ok, request_target, #data{tid=TID, server=Server, kind=Kind, client_spec=ClientSpec}}.

-spec request_target('enter', Msg :: term(), Data :: term()) ->
                            gen_statem:state_enter_result(request_target);
                    (gen_statem:event_type(), Msg :: term(), Data :: term()) ->
                            gen_statem:event_handler_result(atom()).
request_target(enter, _, Data=#data{kind=Kind, server=Server}) ->
    libp2p_group_server:request_target(Server, Kind, self()),
    {next_state, request_target, Data, ?ASSIGN_RETRY};
request_target(timeout, _, #data{}) ->
    repeat_state_and_data;
request_target(cast, {assign_target, undefined}, #data{}) ->
    repeat_state_and_data;
request_target(cast, {assign_target, MAddr}, Data=#data{}) ->
    {next_state, connect, Data#data{target=MAddr}};
request_target(cast, {assign_stream, MAddr, Connection}, Data=#data{}) ->
    %% Use connect_pid to work around the enter action for connect
    %% and re-issue the event in the connect state
    {next_state, connect, Data#data{connect_pid=self(), send_pid=Connection},
     [{next_event, info, {assign_stream, MAddr, Connection}}]};
request_target(cast, {send, Ref, _Bin}, #data{server=Server}) ->
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    keep_state_and_data;
request_target(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec connect('enter', Msg :: term(), Data :: term()) ->
                     gen_statem:state_enter_result(connect);
             (gen_statem:event_type(), Msg :: term(), Data :: term()) ->
                     gen_statem:event_handler_result(atom()).
connect(enter, _, Data=#data{target=Target, tid=TID, connect_pid=undefined}) ->
    Parent = self(),
    {Pid, _} = spawn_monitor(
                 fun() ->
                         case libp2p_transport:connect_to(Target, [], 5000, TID) of
                             {error, Reason} ->
                                 Parent ! {error, Reason};
                             {ok, ConnAddr, SessionPid} ->
                                 libp2p_swarm:register_session(libp2p_swarm:swarm(TID), ConnAddr, SessionPid),
                                 assign_session(Parent, ConnAddr, SessionPid)
                         end
                 end),
    {next_state, connect, Data#data{connect_pid=Pid}};
connect(timeout, _, #data{}) ->
    repeat_state_and_data;
connect(info, {error, Reason}, Data=#data{}) ->
    lager:debug("Connect error: ~p", [Reason]),
    {keep_state, Data#data{connect_pid=undefined}, ?CONNECT_RETRY};
connect(info, {'DOWN', _, process, Pid, normal}, Data=#data{connect_pid=Pid}) ->
    {keep_state, Data#data{connect_pid=undefined}};
connect(info, {'DOWN', _, process, Pid, _}, Data=#data{connect_pid=Pid}) ->
    {keep_state, Data#data{connect_pid=undefined}, ?CONNECT_RETRY};
connect(info, {'DOWN', Monitor, process, _Pid, _Reason}, Data=#data{session_monitor=Monitor}) ->
    {keep_state, Data#data{session_monitor=undefined, send_pid=undefined}, ?CONNECT_RETRY};
connect(cast, {assign_session, _ConnAddr, SessionPid},
        Data=#data{session_monitor=Monitor, client_spec=undefined}) ->
    kill_monitor(Monitor),
    {keep_state, Data#data{session_monitor=erlang:monitor(process, SessionPid),
                           send_pid=undefined}};
connect(cast, {assign_session, _ConnAddr, SessionPid},
        Data=#data{session_monitor=Monitor, client_spec={Path, {M, A}}}) ->
    kill_monitor(Monitor),
    case libp2p_session:start_client_framed_stream(Path, SessionPid, M, A) of
        {ok, ClientPid} ->
            Connection = libp2p_connection:new(M, ClientPid),
            {keep_state, Data#data{session_monitor=erlang:monitor(process, SessionPid),
                                   send_pid=Connection}};
        {error, Error} ->
            lager:info("FAILED TO START CLIENT ~p: ~p", [Path, Error]),
            {keep_state, Data#data{session_monitor=undefined,
                                   send_pid=undefined}, ?CONNECT_RETRY}
    end;
connect(cast, {assign_stream, ConnAddr, Connection}, Data=#data{tid=TID, session_monitor=Monitor}) ->
    kill_monitor(Monitor),
    {ok, SessionPid} = libp2p_config:lookup_session(TID, ConnAddr),
    {keep_state, Data#data{session_monitor=erlang:monitor(process, SessionPid), send_pid=Connection}};
connect(cast, {assign_target, undefined}, Data=#data{session_monitor=Monitor, connect_pid=Process}) ->
    kill_monitor(Monitor),
    kill_connect(Process),
    {next_state, request_target, Data#data{session_monitor=undefined, target=undefined, connect_pid=undefined}};
connect(cast, {send, Ref, _Bin}, #data{server=Server, send_pid=undefined, connect_pid=ConnectPid}) ->
    lager:info("SEND WHILE NOT CONNECTED ~p", [ConnectPid]),
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    keep_state_and_data;
connect(cast, {send, Ref, Bin}, #data{server=Server, send_pid=SendPid}) ->
    Result = libp2p_connection:send(SendPid, Bin),
    libp2p_group_server:send_result(Server, Ref, Result),
    keep_state_and_data;
connect(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec terminate(Reason :: term(), State :: term(), Data :: term()) -> any().
terminate(_Reason, _State, #data{session_monitor=Monitor, connect_pid=Process}) ->
    kill_connect(Process),
    kill_monitor(Monitor).


handle_event(EventType, Msg, #data{}) ->
    lager:warning("Unhandled event ~p: ~p", [EventType, Msg]),
    keep_state_and_data.

%% Utilities

kill_monitor(undefined) ->
    ok;
kill_monitor(Monitor) ->
    erlang:demonitor(Monitor).

kill_connect(undefined) ->
    ok;
kill_connect(Pid) ->
    erlang:exit(Pid, kill).
