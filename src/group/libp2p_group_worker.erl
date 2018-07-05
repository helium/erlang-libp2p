-module(libp2p_group_worker).

-behaviour(gen_statem).
-behavior(libp2p_info).

%% API
-export([start_link/4, assign_target/2, assign_stream/3, send/3, ack/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([request_target/3, connect/3]).

%% libp2p_info
-export([info/1]).

-define(SERVER, ?MODULE).

-record(data,
        { tid :: ets:tab(),
          kind :: atom(),
          server :: pid(),
          client_spec=undefined :: undefined | libp2p_group:stream_client_spec(),
          target=undefined :: undefined | string(),
          send_pid=undefined :: undefined | pid(),
          connect_pid=undefined :: undefined | pid(),
          connect_retry_timer=undefined :: undefined | reference(),
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
    gen_statem:cast(Pid, {assign_stream, MAddr, Connection}).

-spec send(pid(), term(), binary()) -> ok.
send(Pid, Ref, Data) ->
    gen_statem:cast(Pid, {send, Ref, Data}).

-spec ack(pid()) -> ok.
ack(Pid) ->
    gen_statem:cast(Pid, ack).

%% libp2p_info
info(Pid) ->
    gen_statem:call(Pid, info).

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
                             {ok, SessionPid} ->
                                 Parent ! {assign_session, SessionPid}
                         end
                 end),
    {next_state, connect, Data#data{connect_pid=Pid}};
connect(enter, _, Data=#data{connect_pid=ConnectPid})  ->
    {repeat_state, Data#data{connect_pid=kill_pid(ConnectPid)}};
connect(info, connect_retry, Data=#data{}) ->
    {repeat_state, Data#data{connect_retry_timer=undefined}};
connect(cast, {assign_target, undefined}, Data=#data{connect_pid=ConnectPid, session_monitor=Monitor}) ->
    {next_state, request_target, Data#data{connect_pid=kill_pid(ConnectPid),
                                           session_monitor=monitor_session(Monitor, undefined),
                                           send_pid=update_send_pid(undefined, Data)}};
connect(info, {error, _Reason}, Data=#data{}) ->
    {keep_state, connect_retry(Data)};
connect(info, {'DOWN', Monitor, process, _Pid, _Reason}, Data=#data{session_monitor=Monitor}) ->
    %% The _session_ that this worker is monitoring went away. Set a
    %% timer to try again.
    {keep_state, connect_retry(Data#data{session_monitor=undefined,
                                         send_pid=update_send_pid(undefined, Data)})};
connect(info, {'DOWN', _, process, _, normal}, Data=#data{}) ->
    %% Ignore a normal down for the connect pid, since it completed
    %% it's work successfully
    {keep_state, Data#data{connect_pid=undefined}};
connect(info, {'DOWN', _, process, _, _}, Data=#data{}) ->
    %% The connect process wend down for a non-normal reason. Set a
    %% timeout to try again.
    {keep_state, connect_retry(Data#data{connect_pid=undefined})};
connect(info, {assign_session, _SessionPid},
        #data{session_monitor=Monitor}) when Monitor /= undefined ->
    %% Attempting to assign a session when we already have one
    lager:notice("Trying to assign a session while one is being monitored"),
    keep_state_and_data;
connect(info, {assign_session, SessionPid},
        Data=#data{session_monitor=Monitor=undefined, client_spec=undefined}) ->
    %% Assign a session without a client spec. Just monitor the
    %% session. Success, no timeout needed
    {keep_state, Data#data{session_monitor=monitor_session(Monitor, SessionPid),
                           send_pid=update_send_pid(undefined, Data)}};
connect(info, {assign_session, SessionPid},
        Data=#data{session_monitor=Monitor, client_spec={Path, {M, A}}}) ->
    %% Assign session with a client spec. Start client
    case libp2p_session:dial_framed_stream(Path, SessionPid, M, A) of
        {ok, StreamPid} ->
            {keep_state, Data#data{session_monitor=monitor_session(Monitor, SessionPid),
                                   send_pid=update_send_pid(StreamPid, Data)}};
        {error, Error} ->
            lager:notice("Failed to start client on ~p: ~p", [Path, Error]),
            {keep_state, connect_retry(Data#data{session_monitor=monitor_session(Monitor, undefined),
                                                 send_pid=update_send_pid(undefined, Data)})}
    end;
connect(cast, {assign_stream, _MAddr, _StreamPid}, #data{send_pid=SendPid}) when SendPid /= undefined  ->
    %% If send_pid known we have an existing stream. Do not replace.
    keep_state_and_data;
connect(cast, {assign_stream, MAddr, StreamPid},
        Data=#data{tid=TID, session_monitor=Monitor, send_pid=undefined}) ->
    %% Assign a stream. Monitor the session and remember the
    %% connection
    case libp2p_config:lookup_session(TID, MAddr) of
        {ok, SessionPid} ->
            {keep_state, Data#data{session_monitor=monitor_session(Monitor, SessionPid),
                                   send_pid=update_send_pid(StreamPid, Data)}};
        false ->
            keep_state_and_data
    end;
connect(cast, {send, Ref, _Bin}, #data{server=Server, send_pid=undefined}) ->
    %% Trying to send while not connected to a stream
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    keep_state_and_data;
connect(cast, {send, Ref, Bin}, #data{server=Server, send_pid=SendPid}) ->
    Result = libp2p_framed_stream:send(SendPid, Bin),
    libp2p_group_server:send_result(Server, Ref, Result),
    keep_state_and_data;
connect(cast, ack, #data{send_pid=SendPid}) ->
    gen_server:cast(SendPid, ack),
    keep_state_and_data;
connect(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec terminate(Reason :: term(), State :: term(), Data :: term()) -> any().
terminate(_Reason, _State, #data{session_monitor=Monitor, send_pid=SendPid, connect_pid=Process}) ->
    kill_pid(Process),
    kill_pid(SendPid),
    monitor_session(Monitor, undefined).


handle_event(info, {'EXIT', _, normal}, #data{}) ->
    keep_state_and_data;
handle_event(call, info, Data=#data{kind=Kind, server=ServerPid, target=Target,
                                    send_pid=SendPid, session_monitor=SessionMonitor}) ->
    Info = #{
             module => ?MODULE,
             pid => self(),
             kind => Kind,
             server => ServerPid,
             target => Target,
             session =>
                 case SessionMonitor of
                     {_, SessPid} -> SessPid;
                     Other -> Other
                 end,
             stream_info =>
                 case SendPid of
                     undefined -> undefined;
                     SendPid -> libp2p_framed_stream:info(SendPid)
                 end
            },
    {keep_state, Data, [{reply, Info}]};
handle_event(EventType, Msg, #data{}) ->
    lager:warning("Unhandled event ~p: ~p", [EventType, Msg]),
    keep_state_and_data.

%% Utilities

-spec connect_retry(#data{}) -> #data{}.
connect_retry(Data=#data{connect_retry_timer=undefined}) ->
    Timer = erlang:send_after(?CONNECT_RETRY, self(), connect_retry),
    Data#data{connect_retry_timer=Timer};
connect_retry(Data=#data{}) ->
    Data.

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

-spec kill_pid(pid() | undefined) -> undefined.
kill_pid(undefined) ->
    undefined;
kill_pid(Pid) ->
    unlink(Pid),
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
