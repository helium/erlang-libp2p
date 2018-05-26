-module(libp2p_yamux_session).

-include("libp2p_yamux.hrl").

-behaviour(gen_server).

-define(TIMEOUT, 5000).

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

-record(state,
        { connection :: libp2p_connection:connection(),
          tid :: ets:tab(),
          stream_sup :: pid(),
          next_stream_id :: stream_id(),
          sends=#{} :: #{send_id() => send_info()},
          send_pid :: pid(),
          pings=#{} :: #{ping_id() => ping_info()},
          next_ping_id=0 :: ping_id(),
          goaway_state=none :: none | local | remote
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

% gen_server
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).
% API
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
    %% In libp2p_swarm, the server takes over the calling process since
    %% it's fired of synchronously by a multistream.
    init({TID, Connection, Path, 2}).

-spec start_client(libp2p_connection:connection(), string(), ets:tab()) -> {ok, pid()}.
start_client(Connection, Path, TID) ->
    %% In libp2p_swarm the client needs to spawn a new process
    {ok, proc_lib:spawn_link(?MODULE, init, [{TID, Connection, Path, 1}])}.

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

init({TID, Connection, _Path, NextStreamId}) ->
    erlang:process_flag(trap_exit, true),
    {ok, StreamSup} = supervisor:start_link(libp2p_simple_sup, []),
    SendPid = spawn_link(libp2p_connection:mk_async_sender(self(), Connection)),
    State = #state{connection=Connection, tid=TID,
                   stream_sup=StreamSup,
                   send_pid=SendPid,
                   next_stream_id=NextStreamId},
    gen_server:enter_loop(?MODULE, [], fdset(Connection, State), ?TIMEOUT).

handle_info({inert_read, _, _}, State=#state{connection=Connection}) ->
    case read_header(Connection) of
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            lager:error("Session header read failed: ~p ", [Reason]),
            {stop, normal, State};
        {ok, Header=#header{type=HeaderType}} ->
            case HeaderType of
                ?DATA -> {noreply, fdset(Connection, message_receive(Header, State))};
                ?UPDATE -> {noreply, fdset(Connection, message_receive(Header, State))};
                ?GOAWAY -> goaway_receive(Header, fdset(Connection, State));
                ?PING -> {noreply, fdset(Connection, ping_receive(Header, State))}
            end
    end;
handle_info({send_result, Key, Result}, State=#state{sends=Sends}) ->
    case maps:take(Key, Sends) of
        error -> {noreply, State};
        {{Timer, Info}, NewSends} ->
            erlang:cancel_timer(Timer),
            NewState = State#state{sends=NewSends},
            {noreply, handle_send_result(Info, Result, NewState)}
    end;

handle_info({timeout_ping, PingID}, State=#state{}) ->
    {noreply, ping_timeout(PingID, State)};

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
handle_call(ping, From, State=#state{next_ping_id=NextPingID}) ->
    {noreply, session_send({ping, From, NextPingID}, header_ping(NextPingID), ?TIMEOUT,
                           State#state{next_ping_id=NextPingID + 1})};

% Go Away
%
handle_call(goaway, _From, State=#state{goaway_state=local}) ->
    {reply, ok, State};
handle_call(goaway, _From, State=#state{}) ->
    {reply, ok, goaway_cast(?GOAWAY_NORMAL, State)};
handle_call(streams, _From, State=#state{stream_sup=StreamSup}) ->
    {reply, [libp2p_yamux_stream:new_connection(Pid) ||
                {_, Pid, _, _} <- supervisor:which_children(StreamSup)], State};
handle_call(addr_info, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:addr_info(Connection), State};
handle_call(close_state, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:close_state(Connection), State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


terminate(Reason, #state{connection=Connection, send_pid=SendPid}) ->
    fdclr(Connection),
    erlang:exit(SendPid, Reason),
    libp2p_connection:close(Connection).


%%
%% Internal
%%

fdset(Connection, State) ->
    case libp2p_connection:fdset(Connection) of
        ok -> ok;
        {error, Error} -> error(Error)
    end,
    State.

fdclr(Connection) ->
    libp2p_connection:fdclr(Connection).

-spec read_header(libp2p_connection:connection()) -> {ok, header()} | {error, term()}.
read_header(Connection) ->
    case libp2p_connection:recv(Connection, ?HEADER_SIZE) of
        {error, Error} -> {error, Error};
        {ok, Bin}      -> {ok, decode_header(Bin)}
    end.

-spec decode_header(binary()) -> header().
decode_header(<<?VERSION:8/integer-unsigned,
               Type:8/integer-unsigned,
               Flags:16/integer-unsigned-big,
               StreamID:32/integer-unsigned-big,
               Length:32/integer-unsigned-big>>) ->
    #header{type=Type, flags=Flags, stream_id=StreamID, length=Length}.


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

-spec handle_send_result(Info::any(), send_result(), #state{}) -> #state{}.
handle_send_result({ping, From, PingID}, ok, State=#state{pings=Pings}) ->
    TimerRef = erlang:send_after(?TIMEOUT, self(), {timeout_ping, PingID}),
    NewPings = maps:put(PingID, {From, TimerRef, erlang:system_time(millisecond)}, Pings),
    State#state{pings=NewPings};
handle_send_result({ping, From, _}, Error, State=#state{}) ->
    gen_server:reply(From, Error),
    State;
handle_send_result({call, From}, Result, State=#state{}) ->
    gen_server:reply(From, Result),
    State.

%%
%% Ping
%%

-spec ping_timeout(ping_id(), #state{}) -> #state{}.
ping_timeout(PingID, State=#state{pings=Pings}) ->
    case maps:take(PingID, Pings) of
        error -> State;
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
        {{From, TimerRef, StartTime}, NewPings} ->
            erlang:cancel_timer(TimerRef),
            gen_server:reply(From, {ok, erlang:system_time(millisecond) - StartTime}),
            State#state{pings=NewPings}
    end.


%%
%% GoAway
%%

-spec goaway_cast(goaway(), #state{}) -> #state{}.
goaway_cast(Reason, State=#state{}) ->
    session_cast(header_goaway(Reason), State#state{goaway_state=local}).

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
                    lager:notice("Discarding data for missing stream ~p (RST)", [StreamID]),
                    libp2p_connection:recv(Connection, Length),
                    session_cast(header_update(?RST, StreamID, 0), State);
                ?UPDATE when ?FLAG_IS_SET(Flags, ?RST) ->
                    ok; %ignore an inbound RST when the stream is gone
                _ ->
                    lager:notice("Missing stream ~p (RST)" ,[StreamID]),
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
