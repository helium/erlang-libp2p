-module(libp2p_yamux_session).

-include("libp2p_yamux.hrl").

-behaviour(gen_server).

-define(TIMEOUT, 5000).
-define(LIVENESS_TIMEOUT, 30000).
-define(DEFAULT_IDLE_TIMEOUT, 60000).

-define(HEADER_SIZE, 12).
-define(MAX_STREAMID, 4294967295).

-define(VERSION, 0).

-define(DATA,   16#00).
-define(UPDATE, 16#01).
-define(PING,   16#02).
-define(GOAWAY, 16#03).

-define(GOAWAY_NORMAL,   16#00).
-define(GOAWAY_PROTOCOL, 16#01).
-define(GOAWAY_INTERNAL, 16#02).

-record(ident,
       { identify=undefined :: libp2p_identify:identify() | undefined,
         pid=undefined :: pid() | undefined,
         ref :: reference() | undefined,
         waiters=[] :: [term()]
       }).

-record(state,
        { connection=undefined :: libp2p_connection:connection() | undefined,
          tid :: ets:tab(),
          stream_sup :: pid(),
          next_stream_id :: stream_id(),
          sends=#{} :: #{send_id() => send_info()},
          send_pid=undefined :: pid() | undefined,
          pings=#{} :: #{ping_id() => ping_info()},
          next_ping_id=0 :: ping_id(),
          liveness_timer :: reference(),
          idle_timer :: reference(),
          idle_timeout :: pos_integer(),
          goaway_state=none :: none | local | remote,
          ident=#ident{} :: #ident{}
         }).

-record(header, {
          type :: non_neg_integer(),
          flags=0 :: flags(),
          stream_id=0 :: stream_id(),
          length :: non_neg_integer()
         }).

-type header() :: #header{}.
-type stream_id() :: non_neg_integer().
-type ping_id() :: non_neg_integer().
-type ping_info() :: {From::pid(), Timer::reference(), StartTime::integer()}.
-type send_id() :: reference().
-type send_info() :: {Timer::reference(), Info::any()}.
-type send_result() :: ok | {error, term()}.
-type flags() :: non_neg_integer().  % 0 | (bit combo of ?SYN | ?ACK | ?FIN | ?RST)
-type goaway() :: ?GOAWAY_NORMAL | ?GOAWAY_PROTOCOL | ?GOAWAY_INTERNAL.

-export_type([stream_id/0, header/0]).

%% gen_server
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).
%% API
-export([start_server/4, start_client/3]).
-export([send_header/2, send_header/3,
         send_data/3, send_data/4,
         header_length/1,
         header_data/3, header_update/3]).

%%
%% API
%%

-spec start_server(libp2p_connection:connection(), string(), ets:tab(), []) -> no_return().
start_server(Connection, Path, TID, []) ->
    %% In libp2p_swarm, the server takes over the calling process
    %% since it's fired of synchronously by a multistream. Since ranch
    %% already assigned the controlling process, there is no need to
    %% wait for a shoot message
    init({TID, Connection, Path, 2, no_wait_shoot}).

-spec start_client(libp2p_connection:connection(), string(), ets:tab()) -> {ok, pid()}.
start_client(Connection, Path, TID) ->
    %% In libp2p_swarm the client needs to spawn a new process. Since
    %% this is a new process, start_client_session (in
    %% libp2p_transport) will assign the controlling process. Wait for
    %% a shoot message.
    {ok, proc_lib:spawn_link(?MODULE, init, [{TID, Connection, Path, 1, undefined}])}.

call(Pid, Cmd) ->
    try
        gen_server:call(Pid, Cmd, infinity)
    catch
        exit:{noproc, _} ->
            {error, closed};
        exit:{normal, _} ->
            {error, closed};
        exit:{shutdown, _} ->
            {error, closed}
    end.

-spec send_header(pid(), header()) -> ok | {error, term()}.
send_header(Pid, Header=#header{}) ->
    send_header(Pid, Header, ?TIMEOUT).

-spec send_header(pid(), header(), non_neg_integer()) -> ok | {error, term()}.
send_header(Pid, Header=#header{}, Timeout) ->
    call(Pid, {send, encode_header(Header), Timeout}).

-spec send_data(pid(), header(), binary()) -> ok | {error, term()}.
send_data(Pid, Header, Data) ->
    send_data(Pid, Header, Data, ?TIMEOUT).

-spec send_data(pid(), header(), binary(), non_neg_integer()) -> ok | {error, term()}.
send_data(Pid, Header, Data, Timeout) ->
    call(Pid, {send, <<(encode_header(Header))/binary, Data/binary>>, Timeout}).

%%
%% gen_server
%%

init({TID, Connection, _Path, NextStreamId, WaitShoot}) ->
    erlang:process_flag(trap_exit, true),
    {ok, StreamSup} = supervisor:start_link(libp2p_simple_sup, []),
    IdleTimeout = libp2p_config:get_opt(libp2p_swarm:opts(TID), [libp2p_session, idle_timeout],
                                        ?DEFAULT_IDLE_TIMEOUT),

    State = #state{tid=TID,
                   stream_sup=StreamSup,
                   next_stream_id=NextStreamId,
                   liveness_timer=init_liveness_timer(),
                   idle_timeout=IdleTimeout,
                   idle_timer=init_idle_timer(IdleTimeout)
                  },
    %% If we're not waiting for a shoot message with a new connection
    %% we fire one to ourselves to kick of the machinery the same way.
    case WaitShoot of
        no_wait_shoot -> self() ! {shoot_connection, Connection};
        _ -> ok
    end,
    gen_server:enter_loop(?MODULE, [], update_metadata(State), ?TIMEOUT).

handle_info({shoot_connection, NewConnection}, State=#state{send_pid=undefined}) ->
    SendPid = spawn_link(libp2p_connection:mk_async_sender(self(), NewConnection)),
    NewState = update_metadata(State#state{send_pid=SendPid, connection=NewConnection}),
    {noreply, fdset(NewConnection, NewState)};
handle_info({inert_read, _, _}, State=#state{connection=Connection}) ->
    case read_header(Connection) of
        {error, closed} ->
            lager:notice("session closed"),
            {stop, normal, State};
        {error, enotconn} ->
            %% Dont log for enotconn
            {stop, normal, State};
        {error, Reason} ->
            lager:notice("Session header read failed: ~p ", [Reason]),
            {stop, normal, State};
        {ok, Header=#header{type=HeaderType}} ->
            %% Kick the session liveness timer on inbound data
            NewState = kick_liveness_timer(State),
            case HeaderType of
                ?DATA -> {noreply, fdset(Connection, message_receive(Header, NewState))};
                ?UPDATE -> {noreply, fdset(Connection, message_receive(Header, NewState))};
                ?GOAWAY -> goaway_receive(Header, fdset(Connection, NewState));
                ?PING -> {noreply, fdset(Connection, ping_receive(Header, NewState))}
            end
    end;
handle_info({send_result, Key, Result}, State=#state{sends=Sends}) ->
    case maps:take(Key, Sends) of
        error -> {noreply, State};
        {{Timer, Info}, NewSends} ->
            erlang:cancel_timer(Timer),
            NewState = State#state{sends=NewSends},
            handle_send_result(Info, Result, NewState)
    end;

handle_info({timeout_ping, PingID}, State=#state{}) ->
    {noreply, ping_timeout(PingID, State)};
handle_info(timeout_liveness, State=#state{}) ->
    %% No data received.. Send a ping
    {noreply, ping_send(liveness, State)};
handle_info(liveness_failed, State=#state{}) ->
    lager:notice("Session liveness failure"),
    {stop, normal, State};
handle_info(timeout_idle, State=#state{}) ->
    case stream_pids(State) of
        [] ->
            lager:debug("Closing session due to inactivity"),
            {stop, normal, State};
        _ ->
            {noreply, State#state{idle_timer=init_idle_timer(State#state.idle_timeout)}}
    end;

handle_info({stop, {goaway, Code}}, State=#state{}) ->
    lager:debug("got goaway with code ~p, stopping", [Code]),
    {stop, normal, State};
handle_info({stop, Reason}, State=#state{}) ->
    {stop, Reason, State};


%% Identify
%%
handle_info({identify, Handler, HandlerData}, State=#state{ident=#ident{identify=I}}) when I /= undefined ->
    Handler ! {handle_identify, HandlerData, {ok, I}},
    {noreply, State};
handle_info({identify, Handler, HandlerData}, State=#state{ident=Ident=#ident{pid=undefined}, tid=TID}) ->
    {Pid, Ref} = libp2p_stream_identify:dial_spawn(self(), TID, self()),
    NewIdent=Ident#ident{waiters=[{Handler, HandlerData} | Ident#ident.waiters], pid=Pid, ref=Ref},
    {noreply, State#state{ident=NewIdent}};
handle_info({identify, Handler, HandlerData}, State=#state{ident=Ident=#ident{}}) ->
    NewIdent=Ident#ident{waiters=[{Handler, HandlerData} | Ident#ident.waiters]},
    {noreply, State#state{ident=NewIdent}};
handle_info({handle_identify, _Session, Response}, State=#state{ident=Ident=#ident{ref = Ref}}) ->
    erlang:demonitor(Ref, [flush]),
    lists:foreach(fun({Handler, HandlerData}) ->
                          Handler ! {handle_identify, HandlerData, Response}
                  end, Ident#ident.waiters),
    NewIdentify = case Response of
                      {ok, I} -> I;
                      {error, _} -> undefined
                  end,
    {noreply, State#state{ident=Ident#ident{pid=undefined, waiters=[], identify=NewIdentify}}};
handle_info({'DOWN', _Ref, process, _Pid, normal}, State) ->
    %% down beat the reply somehow, ignore and it'll get cleaned up elsewhere
    {noreply, State};
handle_info({'DOWN', Ref, process, Pid, Reason}, State=#state{ident=Ident=#ident{ref = IRef}}) ->
    case IRef == Ref of
        true ->
            lager:warning("crash of known dial ~p ~p ~p", [Ref, Pid, Reason]),
            lists:foreach(fun({Handler, HandlerData}) ->
                                  Handler ! {handle_identify, HandlerData, {error, Reason}}
                          end, Ident#ident.waiters),
            {noreply, State#state{ident=Ident#ident{pid=undefined, waiters=[], identify=undefined}}};
        false  ->
            lager:warning("crash of unknown ref ~p ~p ~p", [Ref, Pid, Reason]),
            {noreply, State}
    end;

handle_info(Msg, State) ->
    lager:warning("Unhandled message: ~p", [Msg]),
    {stop, unknown, State}.

% Open
%
handle_call(open, _From, State=#state{goaway_state=remote}) ->
    {reply, {error, goaway_remote}, State};
handle_call(open, _From, State=#state{next_stream_id=NextStreamID}) when NextStreamID > ?MAX_STREAMID ->
    {reply, {error, streams_exhausted}, State};
handle_call(open, _From, State=#state{next_stream_id=NextStreamID}) ->
    {ok, Connection} = stream_open(NextStreamID, State),
    {reply, {ok, Connection}, State#state{next_stream_id = NextStreamID + 2}};

% Send
%
handle_call({send, Data, Timeout}, From, State) ->
    {noreply, session_send({call, From}, Data, Timeout, State)};

% Ping
%
handle_call(ping, From, State=#state{}) ->
    {noreply, ping_send(From, State)};

% Go Away
%
handle_call(goaway, _From, State=#state{goaway_state=local}) ->
    {reply, ok, State};
handle_call(goaway, _From, State=#state{}) ->
    {reply, ok, goaway_cast(?GOAWAY_NORMAL, State)};
handle_call(streams, _From, State=#state{}) ->
    {reply, [libp2p_yamux_stream:new_connection(Pid) || Pid <- stream_pids(State)], State};
handle_call(addr_info, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:addr_info(Connection), State};
handle_call(close_state, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:close_state(Connection), State};


%% Info
%%
handle_call(info, _From, State=#state{connection=Connection}) ->
    Info = #{
             pid => self(),
             module => ?MODULE,
             addr_info => libp2p_connection:addr_info(Connection),
             stream_info => [libp2p_yamux_stream:info(StreamPid) || StreamPid <- stream_pids(State)]
            },
    {reply, Info, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{connection=Connection, send_pid=SendPid}) ->
    case Connection of
        undefined -> ok;
        _ ->
            libp2p_connection:fdclr(Connection),
            libp2p_connection:close(Connection)
    end,
    case SendPid of
        undefined -> ok;
        _ -> erlang:exit(SendPid, kill)
    end.




%%
%% Internal
%%

fdset(Connection, State) ->
    case libp2p_connection:fdset(Connection) of
        ok -> ok;
        {error, Error} -> error(Error)
    end,
    State.

init_idle_timer(Timeout) ->
    erlang:send_after(Timeout, self(), timeout_idle).

init_liveness_timer() ->
    erlang:send_after(?LIVENESS_TIMEOUT, self(), timeout_liveness).

-spec kick_liveness_timer(#state{}) -> #state{}.
kick_liveness_timer(State) ->
    erlang:cancel_timer(State#state.liveness_timer),
    State#state{liveness_timer=init_liveness_timer()}.

-spec read_header(libp2p_connection:connection()) -> {ok, header()} | {error, term()}.
read_header(Connection) ->
    case libp2p_connection:recv(Connection, ?HEADER_SIZE) of
        {error, Error} -> {error, Error};
        {ok, Bin}      -> decode_header(Bin)
    end.

-spec decode_header(binary()) -> {ok, header()} | {error, term()}.
decode_header(<<?VERSION:8/integer-unsigned,
               Type:8/integer-unsigned,
               Flags:16/integer-unsigned-big,
               StreamID:32/integer-unsigned-big,
               Length:32/integer-unsigned-big>>) ->
    {ok, #header{type=Type, flags=Flags, stream_id=StreamID, length=Length}};
decode_header(_) ->
    {error, bad_header}.



-spec encode_header(header()) -> binary().
encode_header(#header{type=Type, flags=Flags, stream_id=StreamID, length=Length}) ->
    <<?VERSION:8/integer-unsigned,
      Type:8/integer-unsigned,
      Flags:16/integer-unsigned-big,
      StreamID:32/integer-unsigned-big,
      Length:32/integer-unsigned-big>>.


-spec session_send(any(), header() | binary(), non_neg_integer(), #state{}) -> #state{}.
session_send(Info, Header=#header{}, Timeout, State=#state{}) ->
    session_send(Info, encode_header(Header), Timeout, State);
session_send(Info, Data, Timeout, State=#state{send_pid=SendPid, sends=Sends}) when is_binary(Data)->
    Key = make_ref(),
    Timer = erlang:send_after(Timeout, self(), {send_result, Key, {error, timeout}}),
    SendPid ! {send, Key, Data},
    State#state{sends=maps:put(Key, {Timer, Info}, Sends)}.

-spec session_cast(header() | binary(), #state{}) -> #state{}.
session_cast(Header=#header{}, State=#state{}) ->
    session_cast(encode_header(Header), State);
session_cast(Data, State=#state{send_pid=SendPid}) when is_binary(Data) ->
    SendPid ! {cast, Data},
    State.

-spec handle_send_result(Info::any(), send_result(), #state{}) ->
                                {noreply, #state{}} |
                                {stop, normal, #state{}}.
handle_send_result({ping, From, PingID}, ok, State=#state{pings=Pings}) ->
    TimerRef = erlang:send_after(?TIMEOUT, self(), {timeout_ping, PingID}),
    NewPings = maps:put(PingID, {From, TimerRef, erlang:system_time(millisecond)}, Pings),
    {noreply, State#state{pings=NewPings}};
handle_send_result({ping, liveness, _}, _, State=#state{}) ->
    %% On a falure to send a ping from liveness, we're going to assume
    %% the connection is bust.
    self() ! liveness_failed,
    {noreply, State};
handle_send_result({ping, From, _}, Error, State=#state{}) ->
    gen_server:reply(From, Error),
    {noreply, State};
handle_send_result({call, From}, Result = {error, closed}, State=#state{}) ->
    gen_server:reply(From, Result),
    {stop, normal, State};
handle_send_result({call, From}, Result, State=#state{}) ->
    gen_server:reply(From, Result),
    {noreply, State}.

%%
%% Ping
%%

-spec ping_send(liveness | term(), #state{}) -> #state{}.
ping_send(From, State=#state{next_ping_id=NextPingID}) ->
    session_send({ping, From, NextPingID}, header_ping(NextPingID), ?TIMEOUT,
                 State#state{next_ping_id=NextPingID + 1}).

-spec ping_timeout(ping_id(), #state{}) -> #state{}.
ping_timeout(PingID, State=#state{pings=Pings}) ->
    case maps:take(PingID, Pings) of
        error -> State;
        {{liveness, _, _}, Pings2} ->
            %% On a liveness ping response timeout,the liveness check
            %% has failed. We send a message back to ourself to handle
            %% the liveness failure.
            self() ! liveness_failed,
            State#state{pings=Pings2};
        {{From, _, _}, Pings2} ->
            gen_server:reply(From, {error, timeout}),
            State#state{pings=Pings2}
    end.

-spec ping_receive(header(), #state{}) -> #state{}.
ping_receive(#header{flags=Flags, length=PingID}, State=#state{}) when ?FLAG_IS_SET(Flags, ?SYN) ->
    % ping request, respond
    session_cast(header_ping_ack(PingID), State);
ping_receive(#header{length=PingID}, State=#state{pings=Pings}) ->
    % a ping response, cancel timer and respond to the original caller
    % with the ping time
    case maps:take(PingID, Pings) of
        error -> State;
        {{liveness, TimerRef, _}, NewPings} ->
            %% When we receive a ping sent from a liveness check we
            %% just tcancel the timer and kick the liveness timer down
            %% the road again.
            erlang:cancel_timer(TimerRef),
            kick_liveness_timer(State#state{pings=NewPings});
        {{From, TimerRef, StartTime}, NewPings} ->
            erlang:cancel_timer(TimerRef),
            gen_server:reply(From, {ok, erlang:system_time(millisecond) - StartTime}),
            State#state{pings=NewPings}
    end.


%%
%% GoAway
%%

-spec goaway_cast(goaway(), #state{}) -> #state{}.
goaway_cast(Reason=?GOAWAY_NORMAL, State=#state{}) ->
    session_cast(header_goaway(Reason), State#state{goaway_state=local});
goaway_cast(Reason, State=#state{}) ->
    lager:warning("Session going away because of code: ~p", [Reason]),
    self() ! {stop, {goaway, Reason}},
    State.


-spec goaway_receive(header(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
goaway_receive(#header{length=?GOAWAY_NORMAL}, State=#state{connection=Connection}) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    lager:info("Received remote goaway from: ~p", [RemoteAddr]),
    {noreply, State#state{goaway_state=remote}};
goaway_receive(#header{length=Code}, State=#state{}) ->
    lager:error("Received unexpected remote goaway: ~p", [Code]),
    {stop, {remote_goaway, Code}, State}.

%%
%% Stream
%%

-spec stream_pids(#state{}) -> [pid()].
stream_pids(#state{stream_sup=StreamSup}) ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(StreamSup)].

-spec stream_open(stream_id(), #state{}) -> {ok, libp2p_connection:connection()}.
stream_open(StreamID, #state{stream_sup=StreamSup, tid=TID}) ->
    ChildSpec = #{ id => StreamID,
                   start => {libp2p_yamux_stream, open_stream, [self(), TID, StreamID]},
                   restart => temporary,
                   shutdown => 1000,
                   type => worker },
    {ok, Pid} = supervisor:start_child(StreamSup, ChildSpec),
    {ok, libp2p_yamux_stream:new_connection(Pid)}.

-spec stream_receive(stream_id(), #state{}) -> {ok, pid()}.
stream_receive(StreamID, #state{stream_sup=StreamSup, tid=TID}) ->
    ChildSpec = #{ id => StreamID,
                   start => {libp2p_yamux_stream, receive_stream, [self(), TID, StreamID]},
                   restart => temporary,
                   shutdown => 1000,
                   type => worker },
    supervisor:start_child(StreamSup, ChildSpec).


%%
%% Message
%%

-spec message_receive(header(), #state{}) -> #state{}.
message_receive(Header=#header{flags=Flags}, State=#state{}) when ?FLAG_IS_SET(Flags, ?SYN) ->
    NewState = message_receive_stream(Header, State),
    message_receive(Header#header{flags=?FLAG_CLR(Flags, ?SYN)}, NewState);
message_receive(Header=#header{flags=Flags, stream_id=StreamID, type=Type, length=Length},
                State=#state{connection=Connection}) ->
    case stream_lookup(StreamID, State) of
        {error, not_found} ->
            %% Drain any data on the connection sin ce the stream is not found
            case Type of
                ?DATA when Length > 0 ->
                    lager:debug("Discarding data for missing stream ~p (RST)", [StreamID]),
                    libp2p_connection:recv(Connection, Length),
                    session_cast(header_update(?RST, StreamID, 0), State);
                ?UPDATE when ?FLAG_IS_SET(Flags, ?RST) ->
                    ok; %ignore an inbound RST when the stream is gone
                _ ->
                    lager:debug("Missing stream ~p (RST)" ,[StreamID]),
                    session_cast(header_update(?RST, StreamID, 0), State)
            end;
        {ok, Pid} ->
            case Type of
                ?UPDATE ->
                    %Handle an inbound stream window update
                    libp2p_yamux_stream:update_window(Pid, Flags, Header);
                _ ->
                    % Read data and hand of to the stream
                    case libp2p_connection:recv(Connection, Length) of
                        {error, Reason} ->
                            lager:warning("Failed to read data for ~p: ~p", [StreamID, Reason]),
                            goaway_cast(?GOAWAY_INTERNAL, State);
                        {ok, Data} ->
                            libp2p_yamux_stream:receive_data(Pid, Data)
                    end
            end
    end,
    State.

-spec message_receive_stream(header(), #state{}) -> #state{}.
message_receive_stream(#header{stream_id=StreamID}, State=#state{goaway_state=local}) ->
    session_cast(header_update(?RST, StreamID, 0), State);
message_receive_stream(#header{stream_id=StreamID}, State=#state{}) ->
    %% TODO: Send ?RST on accept backlog exceeded
    case stream_lookup(StreamID, State) of
        {ok, _Pid} ->
            lager:notice("Duplicate incoming stream: ~p", [StreamID]),
            goaway_cast(?GOAWAY_PROTOCOL, State);
        {error, not_found} ->
            stream_receive(StreamID, State),
            State
    end.



%%
%% Utilities
%%

-spec stream_lookup(stream_id(), #state{}) -> {ok, pid()} | {error, not_found}.
stream_lookup(StreamID, #state{stream_sup=StreamSup}) ->
    Children = supervisor:which_children(StreamSup),
    case lists:keyfind(StreamID, 1, Children) of
        false -> {error, not_found};
        {StreamID, StreamPid, _, _} -> {ok, StreamPid}
    end.

-spec header_goaway(goaway()) -> header().
header_goaway(Reason) ->
    #header{type=?GOAWAY, flags=0, stream_id=0, length=Reason}.

-spec header_update(flags(), stream_id(), non_neg_integer()) -> header().
header_update(Flags, StreamID, Length) ->
    #header{type=?UPDATE, flags=Flags, stream_id=StreamID, length=Length}.

-spec header_ping(ping_id()) -> header().
header_ping(PingID) ->
    #header{type=?PING, flags=?SYN, stream_id=0, length=PingID}.

-spec header_ping_ack(ping_id()) -> header().
header_ping_ack(PingID) ->
    #header{type=?PING, flags=?ACK, stream_id=0, length=PingID}.

-spec header_data(stream_id(), flags(), non_neg_integer()) -> header().
header_data(StreamID, Flags, Length) ->
    #header{type=?DATA, flags=Flags, stream_id=StreamID, length=Length}.

-spec header_length(header()) -> non_neg_integer().
header_length(#header{length=Length}) ->
    Length.

-spec update_metadata(#state{}) -> #state{}.
update_metadata(State=#state{connection=undefined}) ->
    State;
update_metadata(State=#state{connection=Connection}) ->
    {LocalAddr, RemoteAddr} = libp2p_connection:addr_info(Connection),
    libp2p_lager_metadata:update(
      [
       {session_local, LocalAddr},
       {session_remote, RemoteAddr}
      ]),
    State.
