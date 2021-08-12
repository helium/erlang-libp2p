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
         acknowledge/2, fdset/1, socket/1, fdclr/1,
         addr_info/1, close/1, close_state/1,
         controlling_process/2, session/1, monitor/1,
         set_idle_timeout/2]).
-export([mk_async_sender/2]).

-callback acknowledge(any(), any()) -> ok.
-callback send(any(), iodata(), non_neg_integer() | infinity) -> ok | {error, term()}.
-callback recv(any(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
-callback close(any()) -> ok.
-callback close_state(any()) -> close_state().
-callback fdset(any()) -> ok | {error, term()}.
-callback fdclr(any()) -> ok.
-callback addr_info(any()) -> {string(), string()}.
-callback session(any()) -> {ok, pid()} | {error, term()}.
-callback set_idle_timeout(any(), pos_integer() | infinity) -> ok | {error, term()}.
-callback controlling_process(any(), pid()) ->  {ok, any()} | {error, closed | not_owner | atom()}.
-callback monitor(any()) -> reference().

-define(RECV_TIMEOUT, 60000).
-define(SEND_TIMEOUT, 60000).

-spec new(atom(), any()) -> connection().
new(Module, State) ->
    #connection{module=Module, state=State}.

-spec send(connection(), iodata()) -> ok | {error, term()}.
send(#connection{module=Module, state=State}, Data) ->
    Module:send(State, Data, ?SEND_TIMEOUT).

-spec send(connection(), iodata(), non_neg_integer() | infinity) -> ok | {error, term()}.
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

-spec socket(connection()) -> any().
socket(#connection{module=Module, state=State}) ->
    Module:socket(State).

-spec fdclr(connection()) -> ok | {error, term()}.
fdclr(#connection{module=Module, state=State}) ->
    Module:fdclr(State).

-spec addr_info(connection()) -> {string(), string()}.
addr_info(#connection{module=Module, state=State}) ->
    Module:addr_info(State).

-spec session(connection()) ->  {ok, pid()} | {error, term()}.
session(#connection{module=Module, state=State}) ->
    Module:session(State).

-spec set_idle_timeout(connection(), pos_integer() | infinity) -> ok | {error, term()}.
set_idle_timeout(#connection{module=Module, state=State}, Timeout) ->
    Module:set_idle_timeout(State, Timeout).

-spec controlling_process(connection(), pid())-> {ok, connection()} | {error, closed | not_owner | atom()}.
controlling_process(Conn=#connection{module=Module, state=State}, Pid) ->
    case Module:controlling_process(State, Pid) of
        {ok, NewState} ->
            NewConn = Conn#connection{state=NewState},
            Pid ! {shoot_connection, NewConn},
            {ok, NewConn};
        Other -> Other
    end.

-spec monitor(connection())-> reference().
monitor(#connection{module=Module, state=State}) ->
    Module:monitor(State).

%%
%% Utilities
%%

-spec mk_async_sender(pid(), libp2p_connection:connection()) -> fun().
mk_async_sender(Handler, Connection) ->
    Parent = self(),
    Sender = fun Fun() ->
                     receive
                         {'DOWN', _, process, Parent, _} ->
                             ok;
                         {send, Ref, Data} ->
                             case (catch libp2p_connection:send(Connection, Data)) of
                                 {'EXIT', Error} ->
                                     lager:notice("Failed sending on connection for ~p: ~p",
                                                  [Handler, Error]),
                                     Handler ! {send_result, Ref, {error, Error}};
                                 Result ->
                                     Handler ! {send_result, Ref, Result}
                             end,
                             Fun();
                         {cast, Data} ->
                             case (catch libp2p_connection:send(Connection, Data)) of
                                 {'EXIT', Error} ->
                                     lager:notice("Failed casting on connection for ~p: ~p",
                                                  [Handler, Error]);
                                 _ ->
                                     ok
                             end,
                             Fun()
                     end
             end,
    fun() ->
            erlang:put(async_sender_for, Parent),
            erlang:monitor(process, Parent),
            Sender()
    end.
