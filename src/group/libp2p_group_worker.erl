-module(libp2p_group_worker).

-behaviour(gen_statem).

%% API
-export([start_link/4, assign_target/2, assign_stream/3, send/3]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([request_target/3, connect/3]).

-define(SERVER, ?MODULE).

-record(data,
        { tid :: ets:tab(),
          kind :: atom(),
          server :: pid(),
          client_spec=undefined :: undefined | libp2p_group:stream_client_spec(),
          target=undefined :: undefined | string(),
          send_pid=undefined :: undefined | libp2p_connection:connection(),
          connect_pid=undefined :: undefined | pid(),
          session_monitor=undefined :: session_monitor()
        }).

-define(ASSIGN_RETRY, 500).
-define(CONNECT_RETRY, 1000).

-type session_monitor() :: undefined | {reference(), pid()}.

%% API

-spec assign_target(pid(), string() | undefined) -> ok.
assign_target(Pid, MAddr) ->
    gen_statem:cast(Pid, {assign_target, MAddr}).

assign_stream(Pid, MAddr, Connection) ->
    gen_statem:call(Pid, {assign_stream, MAddr, Connection}).

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
request_target(cast, {send, Ref, _Bin}, #data{server=Server}) ->
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    {keep_state_and_data, ?ASSIGN_RETRY};
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
                             {ok, _Addr, SessionPid} ->
                                 {_, RemoteAddr} = libp2p_session:addr_info(SessionPid),
                                 Parent ! {assign_session, RemoteAddr, SessionPid}
                         end
                 end),
    {next_state, connect, Data#data{connect_pid=Pid}};
connect(enter, _, Data=#data{connect_pid=ConnectPid})  ->
    kill_connect(ConnectPid),
    {repeat_state, Data#data{connect_pid=undefined}};
connect(timeout, _, #data{}) ->
    repeat_state_and_data;
connect(info, {error, _Reason}, Data=#data{}) ->
    {keep_state, Data, ?CONNECT_RETRY};
connect(info, {'DOWN', Monitor, process, _Pid, _Reason}, Data=#data{session_monitor=Monitor}) ->
    %% The _session_ that this worker is monitoring went away. Set a
    %% timer to try again.
    {keep_state, Data#data{session_monitor=undefined,
                           send_pid=update_send_pid(undefined, Data)},
     ?CONNECT_RETRY};
connect(info, {'DOWN', _, process, _, normal}, Data=#data{}) ->
    %% Ignore a normal down for the connect pid, since it completed
    %% it's work successfully
    {keep_state, Data#data{connect_pid=undefined}};
connect(info, {'DOWN', _, process, _, _}, Data=#data{}) ->
    %% The connect process wend down for a non-normal reason. Set a
    %% timeout to try again.
    {keep_state, Data#data{connect_pid=undefined}, ?CONNECT_RETRY};
connect(info, {assign_session, _ConnAddr, _SessionPid},
        #data{session_monitor=Monitor}) when Monitor /= undefined ->
    %% Attempting to assign a session when we already have one
    lager:notice("Trying to assign a session while one is being monitored"),
    {keep_state_and_data, ?CONNECT_RETRY};
connect(info, {assign_session, _ConnAddr, SessionPid},
        Data=#data{session_monitor=Monitor=undefined, client_spec=undefined}) ->
    %% Assign a session without a client spec. Just monitor the
    %% session. Success, no timeout needed
    {keep_state, Data#data{session_monitor=monitor_session(Monitor, SessionPid),
                           send_pid=update_send_pid(undefined, Data)}};
connect(info, {assign_session, _ConnAddr, SessionPid},
        Data=#data{session_monitor=Monitor, client_spec={Path, {M, A}}}) ->
    %% Assign session with a client spec. Start client
    case libp2p_session:start_client_framed_stream(Path, SessionPid, M, A) of
        {ok, ClientPid} ->
            Connection = libp2p_connection:new(M, ClientPid),
            {keep_state, Data#data{session_monitor=monitor_session(Monitor, SessionPid),
                                   send_pid=update_send_pid(Connection, Data)}};
        {error, Error} ->
            lager:notice("Failed to start client on ~p: ~p", [Path, Error]),
            {keep_state, Data#data{session_monitor=monitor_session(Monitor, undefined),
                                   send_pid=update_send_pid(undefined, Data)},
             ?CONNECT_RETRY}
    end;
connect({call, From}, {assign_stream, _MAddr, _Connection}, #data{send_pid=SendPid}) when SendPid /= undefined  ->
    %% If send_pid known we have an existing stream. Do not replace.
    {keep_state_and_data, [{reply, From, {error, already_connected}}]};
connect({call, From}, {assign_stream, MAddr, Connection},
        Data=#data{tid=TID, session_monitor=Monitor, send_pid=undefined}) ->
    %% Assign a stream. Monitor the session and remember the
    %% connection
    {ok, SessionPid} = libp2p_config:lookup_session(TID, MAddr),
    {keep_state, Data#data{session_monitor=monitor_session(Monitor, SessionPid),
                           send_pid=update_send_pid(Connection, Data)},
    [{reply, From, ok}]};
connect(cast, {send, Ref, _Bin}, #data{server=Server, send_pid=undefined}) ->
    %% Trying to send while not connected to a stream
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    keep_state_and_data;
connect(cast, {send, Ref, Bin}, Data=#data{server=Server, send_pid=SendPid, session_monitor=Monitor}) ->
    Result = libp2p_connection:send(SendPid, Bin),
    libp2p_group_server:send_result(Server, Ref, Result),
    case Result of
        ok ->
            keep_state_and_data;
        _ ->
            %% TODO: This should NOT need to happen. The theory here
            %% is that the session gets wedged trying to send partial
            %% data and as a result can't hear a receipt. This hammer
            %% just terminates the session altogether to see if this
            %% is actually true.
            {_, SessionPid} = Monitor,
            libp2p_session:close(SessionPid),
            {next_state, request_target, Data#data{send_pid=update_send_pid(undefined, Data),
                                                   session_monitor=monitor_session(Monitor, undefined)}}
    end;
connect(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec terminate(Reason :: term(), State :: term(), Data :: term()) -> any().
terminate(_Reason, _State, #data{session_monitor=Monitor, connect_pid=Process}) ->
    kill_connect(Process),
    monitor_session(Monitor, undefined).


handle_event(EventType, Msg, #data{}) ->
    lager:warning("Unhandled event ~p: ~p", [EventType, Msg]),
    keep_state_and_data.

%% Utilities

-spec monitor_session(Monitor::session_monitor(), SessionPid::pid() | undefined) -> undefined | session_monitor().
monitor_session(undefined, undefined) ->
    undefined;
monitor_session({Monitor, _}, undefined) ->
    erlang:demonitor(Monitor),
    undefined;
monitor_session(undefined, SessionPid) ->
    {erlang:monitor(process, SessionPid), SessionPid};
monitor_session({Monitor, _}, SessionPid) ->
    erlang:demonitor(Monitor),
    {erlang:monitor(process, SessionPid), SessionPid}.

-spec kill_connect(pid() | undefined) -> undefined.
kill_connect(undefined) ->
    undefined;
kill_connect(Pid) ->
    erlang:exit(Pid, kill),
    undefined.

update_send_pid(SendPid, #data{send_pid=SendPid}) ->
    SendPid;
update_send_pid(SendPid, #data{kind=Kind, server=Server}) ->
    Notice = case SendPid of
                 undefined -> false;
                 _ -> true
             end,
    libp2p_group_server:send_ready(Server, Kind, Notice),
    SendPid.
