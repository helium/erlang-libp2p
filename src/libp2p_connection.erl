-module(libp2p_connection).

-record(connection, {
          module :: module(),
          state :: any()
         }).

-type connection() :: #connection{}.

-export_type([connection/0]).

-export([new/2, send/2, recv/2, acknowledge/1, set_options/2, close/1]).

-callback send(any(), iodata()) -> ok | {error, term()}.
-callback recv(any(), non_neg_integer()) -> binary() | {error, term()}.
-callback close(any()) -> ok.
-callback set_options(any(), any()) -> ok | {error, term()}.

-spec new(atom(), any()) -> connection().
new(Module, State) ->
    #connection{module=Module, state=State}.


-spec send(connection(), iodata()) -> ok | {error, term()}.
send(#connection{module=Module, state=State}, Data) ->
    Module:send(State, Data).

-spec recv(connection(), non_neg_integer()) -> binary() | {error, term()}.
recv(#connection{module=Module, state=State}, Length) ->
    Module:recv(State, Length).

-spec acknowledge(connection()) -> ok.
acknowledge(#connection{module=Module, state=State}) ->
    Module:acknowledge(State).

-spec close(connection()) -> ok.
close(#connection{module=Module, state=State}) ->
    Module:close(State).

-spec set_options(connection(), any()) -> ok | {error, term()}.
set_options(#connection{module=Module, state=State}, Options) ->
    Module:set_options(State, Options).
