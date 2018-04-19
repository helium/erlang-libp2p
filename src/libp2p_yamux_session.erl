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

-record(state, {
          connection :: libp2p_connection:connection(),
          tid :: ets:tab(),
          stream_sup :: pid(),
          next_stream_id :: stream_id(),
          pings=#{} :: #{ping_id() => reference()},
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
-type flags() :: non_neg_integer().  % 0 | (bit combo of ?SYN | ?ACK | ?FIN | ?RST)
-type goaway() :: ?GOAWAY_NORMAL | ?GOAWAY_PROTOCOL | ?GOAWAY_INTERNAL.

-export_type([stream_id/0, header/0]).

% gen_server
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).
% API
-export([start_server/4, start_client/3]).
-export([send/2, send/3,
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
        gen_server:call(Pid, Cmd)
    catch
        exit:{noproc, _} ->
            {error, closed};
        exit:{normal, _} ->
            {error, closed};
        exit:{shutdown, _} ->
            {error, closed}
    end.

-spec send(pid(), header() | binary()) -> ok | {error, term()}.
send(Pid, Header=#header{}) ->
    send(Pid, encode_header(Header));
send(Pid, Data) when is_binary(Data) ->
    call(Pid, {send, Data}).

-spec send(pid(), header() | binary(), binary()) -> ok | {error, term()}.
send(Pid, Header=#header{}, Data) ->
    send(Pid, encode_header(Header), Data);
send(Pid, Header, Data) ->
    call(Pid, {send, <<Header/binary, Data/binary>>}).

%%
%% gen_server
%%

init({TID, Connection, _Path, NextStreamId}) ->
    erlang:process_flag(trap_exit, true),
    {ok, StreamSup} = supervisor:start_link(libp2p_simple_sup, []),
    State = #state{connection=Connection, tid=TID,
                   stream_sup=StreamSup, next_stream_id=NextStreamId},
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
handle_info({timeout_ping, PingID}, State=#state{}) ->
    {noreply, ping_timeout(PingID, State)};

handle_info(timeout, State) ->
    {stop, normal, State};
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
handle_call({send, Data}, _From, State) ->
    {reply, session_send(Data, State), State};

% Ping
%
handle_call(ping, From, State=#state{}) ->
    case ping_send(From, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, NewState} -> {noreply, NewState}
    end;

% Go Away
%
handle_call(goaway, _From, State=#state{goaway_state=local}) ->
    {reply, ok, State};
handle_call(goaway, _From, State=#state{}) ->
    {reply, ok, goaway_send(?GOAWAY_NORMAL, State)};
handle_call(streams, _From, State=#state{stream_sup=StreamSup}) ->
    {reply, [Pid || {_, Pid, _, _} <- supervisor:which_children(StreamSup)], State};
handle_call(addr_info, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:addr_info(Connection), State};
handle_call(close_state, _From, State=#state{connection=Connection}) ->
    {reply, libp2p_connection:close_state(Connection), State};

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.


terminate(_Reason, #state{connection=Connection}) ->
    fdclr(Connection),
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


%%
%% Ping
%%

-spec ping_send(pid(), #state{}) -> {ok, #state{}} | {error, term()}.
ping_send(From, State=#state{tid=TID, next_ping_id=NextPingID, pings=Pings}) ->
    case session_send(header_ping(NextPingID), State) of
        {error, Error} -> {error, Error};
        ok ->
            Opts = libp2p_swarm:opts(TID, []),
            WriteTimeOut = libp2p_config:get_opt(Opts, [?MODULE, write_timeout], ?DEFAULT_WRITE_TIMEOUT),
            TimerRef = erlang:send_after(WriteTimeOut, self(), {timeout_ping, NextPingID}),
            Pings2 = maps:put(NextPingID, {From, erlang:system_time(millisecond), TimerRef}, Pings),
            {ok, State#state{next_ping_id=NextPingID + 1, pings=Pings2}}
    end.

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
    session_send(header_ping_ack(PingID), State),
    State;
ping_receive(#header{length=PingID}, State=#state{pings=Pings}) ->
    % a ping response, cancel timer and respond to the original caller
    % with the ping time
    case maps:take(PingID, Pings) of
        error -> State;
        {{From, StartTime, TimerRef}, Pings2} ->
            erlang:cancel_timer(TimerRef),
            gen_server:reply(From, {ok, erlang:system_time(millisecond) - StartTime}),
            State#state{pings=Pings2}
    end.


%%
%% GoAway
%%

-spec goaway_send(goaway(), #state{}) -> #state{}.
goaway_send(Reason, State=#state{}) ->
    session_send(header_goaway(Reason), State),
    State#state{goaway_state=local}.

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
                    session_send(header_update(?RST, StreamID, 0), State);
                ?UPDATE when ?FLAG_IS_SET(Flags, ?RST) ->
                    ok; %ignore an inbound RST when the stream is gone
                _ ->
                    lager:notice("Missing stream ~p (RST)" ,[StreamID]),
                    session_send(header_update(?RST, StreamID, 0), State)
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
                            goaway_send(?GOAWAY_INTERNAL, State);
                        {ok, Data} ->
                            libp2p_yamux_stream:receive_data(Pid, Data)
                    end
            end
    end,
    State.

-spec message_receive_stream(header(), #state{}) -> #state{}.
message_receive_stream(#header{stream_id=StreamID}, State=#state{goaway_state=local}) ->
    session_send(header_update(?RST, StreamID, 0), State),
    State;
message_receive_stream(#header{stream_id=StreamID}, State=#state{}) ->
    %% TODO: Send ?RST on accept backlog exceeded
    case stream_lookup(StreamID, State) of
        {ok, _Pid} ->
            lager:notice("Duplicate incoming stream: ~p", [StreamID]),
            goaway_send(?GOAWAY_PROTOCOL, State);
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

-spec session_send(header() | binary(), #state{}) -> ok | {error, term()}.
session_send(Header=#header{}, State=#state{}) ->
    session_send(encode_header(Header), State);
session_send(Data, #state{connection=Connection}) when is_binary(Data)->
    case libp2p_connection:send(Connection, Data) of
        {error, Reason} ->
            lager:info("Failed to send data: ~p", [Reason]),
            {error, Reason};
        ok -> ok
    end.
