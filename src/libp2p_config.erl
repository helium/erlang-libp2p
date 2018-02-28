-module(libp2p_config).

-export([get_config/2,
         insert_pid/4, lookup_pid/3, lookup_pids/2, remove_pid/3,
         session/0, insert_session/3, lookup_session/2, lookup_session/3, remove_session/2, lookup_sessions/1,
         transport/0, insert_transport/3, lookup_transport/2, lookup_transports/1,
         listen_addrs/1, listener/0, lookup_listener/2, insert_listener/3, remove_listener/2,
         lookup_connection_handlers/1, insert_connection_handler/2,
         lookup_stream_handlers/1, insert_stream_handler/2]).

-define(CONNECTION_HANDLER, connection_handler).
-define(STREAM_HANDLER, stream_handler).
-define(TRANSPORT, transport).
-define(SESSION, session).
-define(LISTENER, listener).

-type handler() :: {atom(), atom()}.

%%
%% Global config
%%

get_config(Module, Defaults) ->
    case application:get_env(Module) of
        undefined -> Defaults;
        {ok, Values} ->
            sets:to_list(sets:union(sets:from_list(Values),
                                    sets:from_list(Defaults)))
    end.

%%
%% Common pid CRUD
%%

-spec insert_pid(ets:tab(), atom(), term(), pid()) -> true.
insert_pid(TID, Kind, Ref, Pid) ->
    ets:insert(TID, {{Kind, Ref}, Pid}).

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


-spec lookup_handlers(ets:tab(), atom()) -> [{term(), any()}].
lookup_handlers(TID, TableKey) ->
    [ {Key, Handler} ||
        [Key, Handler] <- ets:match(TID, {{TableKey, '$1'}, '$2'})].


%%
%% Transports
%%
-spec transport() -> ?TRANSPORT.
transport() ->
    ?TRANSPORT.

-spec insert_transport(ets:tab(), atom(), pid()) -> true.
insert_transport(TID, Module, Pid) ->
    insert_pid(TID, ?TRANSPORT, Module, Pid).

-spec lookup_transport(ets:tab(), atom()) -> {ok, pid()} | false.
lookup_transport(TID, Module) ->
    lookup_pid(TID, ?TRANSPORT, Module).

-spec lookup_transports(ets:tab()) -> [{term(), pid()}].
lookup_transports(TID) ->
    lookup_pids(TID, ?TRANSPORT).


%%
%% Listeners
%%
-spec listener() -> ?LISTENER.
listener() ->
    ?LISTENER.

-spec insert_listener(ets:tab(), string(), pid()) -> true.
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

%%
%% Sessions
%%

-spec session() -> ?SESSION.
session() ->
    ?SESSION.

-spec insert_session(ets:tab(), string(), pid()) -> true.
insert_session(TID, Addr, Pid) ->
    insert_pid(TID, ?SESSION, Addr, Pid).

-spec lookup_session(ets:tab(), string(), libp2p_swarm:connect_opt())
                    -> {ok, pid()} | false.
lookup_session(TID, Addr, Options) ->
    case lists:keyfind(unique_session, 1, Options) of
        {unique_session, true} -> false;
        _ -> lookup_pid(TID, ?SESSION, Addr)
    end.

-spec lookup_session(ets:tab(), string()) -> {ok, pid()} | false.
lookup_session(TID, Addr) ->
    lookup_session(TID, Addr, []).

-spec remove_session(ets:tab(), string()) -> true.
remove_session(TID, Addr) ->
    remove_pid(TID, ?SESSION, Addr).

-spec lookup_sessions(ets:tab()) -> [{term(), pid()}].
lookup_sessions(TID) ->
    lookup_pids(TID, ?SESSION).


%%
%% Connections
%%

-spec lookup_connection_handlers(ets:tab()) -> [{string(), {handler(), handler()}}].
lookup_connection_handlers(TID) ->
    lookup_handlers(TID, ?CONNECTION_HANDLER).

-spec insert_connection_handler(ets:tab(), {string(), handler(), handler()}) -> true.
insert_connection_handler(TID, {Key, ServerMF, ClientMF}) ->
    ets:insert(TID, {{?CONNECTION_HANDLER, Key}, {ServerMF, ClientMF}}).

%%
%% Streams
%%

-spec lookup_stream_handlers(ets:tab()) -> [{string(), handler()}].
lookup_stream_handlers(TID) ->
    lookup_handlers(TID, ?STREAM_HANDLER).

-spec insert_stream_handler(ets:tab(), {string(), handler()}) -> true.
insert_stream_handler(TID, {Key, ServerMF}) ->
    ets:insert(TID, {{?STREAM_HANDLER, Key}, ServerMF}).
