-module(libp2p_config).

-export([insert_pid/4, lookup_pid/3, lookup_pids/2, remove_pid/3,
         insert_session/3, lookup_session/2, remove_session/2, lookup_sessions/1,
         insert_handler/3, lookup_handler/2,
         listen_addrs/1, lookup_listener/2, insert_listener/3, remove_listener/2,
         lookup_connection_handlers/1, insert_connection_handler/2,
         lookup_stream_handlers/1, insert_stream_handler/2]).

-define(CONNECTION_HANDLER, connection_handler).
-define(STREAM_HANDLER, stream_handler).
-define(SESSION, session).
-define(LISTENER, listener).
-define(HANDLER, handler).

-type handler() :: {atom(), atom()}.


-spec insert_pid(ets:tab(), atom(), term(), pid()) -> atom().
insert_pid(TID, Kind, Ref, Pid) ->
    ets:insert(TID, {{Kind, Ref}, Pid}),
    Kind.

-spec lookup_pid(ets:tab(), atom(), term()) -> {ok, pid()} | false.
lookup_pid(TID, Kind, Ref) ->
    case ets:lookup(TID, {Kind, Ref}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> false
    end.

-spec lookup_pids(ets:tab(), atom()) -> [{term(), pid()}].
lookup_pids(TID, Kind) ->
    [{Addr, Pid} || [Addr, Pid] <- ets:match(TID, {{Kind, '$1'}, '$2'})].

-spec remove_pid(ets:tab(), atom(), term()) -> true.
remove_pid(TID, Kind, Ref) ->
    ets:delete(TID, {Kind, Ref}).

-spec insert_listener(ets:tab(), string(), pid()) -> atom().
insert_listener(TID, Addr, Pid) ->
    insert_pid(TID, ?LISTENER, Addr, Pid).

-spec lookup_listener(ets:tab(), string()) -> {ok, pid()} | false.
lookup_listener(TID, Addr) ->
    lookup_pid(TID, ?LISTENER, Addr).

-spec remove_listener(ets:tab(), string()) -> true.
remove_listener(TID, Addr) ->
    remove_pid(TID, ?LISTENER, Addr).

-spec listen_addrs(ets:tab()) -> [string()].
listen_addrs(TID) ->
    [ Addr || [Addr] <- ets:match(TID, {{?LISTENER, '$1'}, '_'})].

-spec insert_session(ets:tab(), string(), pid()) -> atom().
insert_session(TID, Addr, Pid) ->
    insert_pid(TID, ?SESSION, Addr, Pid).

-spec lookup_session(ets:tab(), string()) -> {ok, pid()} | false.
lookup_session(TID, Addr) ->
    lookup_pid(TID, ?SESSION, Addr).

-spec remove_session(ets:tab(), string()) -> true.
remove_session(TID, Addr) ->
    remove_pid(TID, ?SESSION, Addr).

-spec lookup_sessions(ets:tab()) -> [{term(), pid()}].
lookup_sessions(TID) ->
    lookup_pids(TID, ?SESSION).

-spec insert_handler(ets:tab(), string(), pid()) -> atom().
insert_handler(TID, Ref, Pid) ->
    insert_pid(TID, ?HANDLER, Ref, Pid).

-spec lookup_handler(ets:tab(), string()) -> {ok, pid()} | false.
lookup_handler(TID, Ref) ->
    lookup_pid(TID, ?HANDLER, Ref).

%%
%% Connections
%%

-spec lookup_handlers(ets:tab(), atom()) -> [{string(), term()}].
lookup_handlers(TID, TableKey) ->
    [ {Key, Handler} ||
        [Key, Handler] <- ets:match(TID, {{TableKey, '$1'}, '$2'})].

-spec lookup_connection_handlers(ets:tab()) -> [{string(), {handler(), handler()}}].
lookup_connection_handlers(TID) ->
    lookup_handlers(TID, ?CONNECTION_HANDLER).

-spec insert_connection_handler(ets:tab(), {string(), handler(), handler()}) -> ok.
insert_connection_handler(TID, {Key, ServerMF, ClientMF}) ->
    ets:insert(TID, {{?CONNECTION_HANDLER, Key}, {ServerMF, ClientMF}}),
    ok.

%%
%% Streams
%%

-spec lookup_stream_handlers(ets:tab()) -> [{string(), handler()}].
lookup_stream_handlers(TID) ->
    lookup_handlers(TID, ?STREAM_HANDLER).

-spec insert_stream_handler(ets:tab(), {string(), handler()}) -> ok.
insert_stream_handler(TID, {Key, ServerMF}) ->
    ets:insert(TID, {{?STREAM_HANDLER, Key}, ServerMF}),
    ok.
