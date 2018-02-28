-module(libp2p_connection).

-record(connection, {
          module :: module(),
          state :: any()
         }).

-type connection() :: #connection{}.
-type close_state() :: open | closed | pending.

-export_type([connection/0, close_state/0]).

-export([new/2, send/2, send/3,
         recv/1, recv/2, recv/3,
         acknowledge/2, fdset/1, fdclr/1,
         addr_info/1, close/1, close_state/1,
         controlling_process/2]).

-callback acknowledge(any(), any()) -> ok.
-callback send(any(), iodata(), non_neg_integer()) -> ok | {error, term()}.
-callback recv(any(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
-callback close(any()) -> ok.
-callback close_state(any()) -> close_state().
-callback fdset(any()) -> ok | {error, term()}.
-callback fdclr(any()) -> ok.
-callback addr_info(any()) -> {string(), string()}.
-callback controlling_process(any(), pid()) ->  ok | {error, closed | not_owner | atom()}.

-define(RECV_TIMEOUT, 5000).
-define(SEND_TIMEOUT, 5000).

-spec new(atom(), any()) -> connection().
new(Module, State) ->
    #connection{module=Module, state=State}.

-spec send(connection(), iodata()) -> ok | {error, term()}.
send(#connection{module=Module, state=State}, Data) ->
    Module:send(State, Data, ?SEND_TIMEOUT).

-spec send(connection(), iodata(), non_neg_integer()) -> ok | {error, term()}.
send(#connection{module=Module, state=State}, Data, Timeout) ->
    Module:send(State, Data, Timeout).

-spec recv(connection()) -> {ok, binary()} | {error, term()}.
recv(Conn=#connection{}) ->
    recv(Conn, 0).

-spec recv(connection(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
recv(Conn=#connection{}, Length) ->
    recv(Conn, Length, ?RECV_TIMEOUT).

-spec recv(connection(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
recv(#connection{module=Module, state=State}, Length, Timeout) ->
    Module:recv(State, Length, Timeout).

-spec acknowledge(connection(), any()) -> ok.
acknowledge(#connection{module=Module, state=State}, Ref) ->
    Module:acknowledge(State, Ref).

-spec close(connection()) -> ok.
close(#connection{module=Module, state=State}) ->
    Module:close(State).

-spec close_state(connection()) -> close_state().
close_state(#connection{module=Module, state=State}) ->
    Module:close_state(State).

-spec fdset(connection()) -> ok | {error, term()}.
fdset(#connection{module=Module, state=State}) ->
    Module:fdset(State).

-spec fdclr(connection()) -> ok | {error, term()}.
fdclr(#connection{module=Module, state=State}) ->
    Module:fdclr(State).

-spec addr_info(connection()) -> {string(), string()}.
addr_info(#connection{module=Module, state=State}) ->
    Module:addr_info(State).

-spec controlling_process(connection(), pid())-> ok | {error, closed | not_owner | atom()}.
controlling_process(#connection{module=Module, state=State}, Pid) ->
    Module:controlling_process(State, Pid).
