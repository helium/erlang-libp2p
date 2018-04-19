-module(libp2p_config).

-export([get_opt/2, get_opt/3,
         data_dir/0, data_dir/1, data_dir/2,
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
-type opts() :: [{atom(), any()}].

-export_type([opts/0]).

%%
%% Global config
%%

-spec get_opt(opts(), atom() | list()) -> undefined | {ok, any()}.
get_opt(Opts, L) when is_list(Opts), is_list(L)  ->
    get_opt_l(L, Opts);
get_opt(Opts, K) when is_list(Opts), is_atom(K) ->
    get_opt_l([K], Opts).

-spec get_opt(opts(), atom() | list(), any()) -> any().
get_opt(Opts, K, Default) ->
    case get_opt(Opts, K) of
        {ok, V}   -> V;
        undefined -> Default
    end.

get_opt_l([], V) ->
    {ok, V};
get_opt_l([H|T], [_|_] = L) ->
    case lists:keyfind(H, 1, L) of
        {_, V} ->
            get_opt_l(T, V);
        false ->
            undefined
    end;
get_opt_l(_, _) ->
    undefined.


-spec data_dir() -> string().
data_dir() ->
    "data".

-spec data_dir(ets:tab()) -> string().
data_dir(Name) when is_atom(Name) ->
    filename:join(data_dir(), Name);
data_dir(TID) ->
    data_dir(libp2p_swarm:name(TID)).

-spec data_dir(ets:tab() | string(), file:name_all()) -> string().
data_dir(Dir, Name) when is_list(Dir) ->
    FileName = filename:join(Dir, Name),
    ok = filelib:ensure_dir(FileName),
    FileName;
data_dir(TID, Name) ->
    data_dir(data_dir(TID), Name).

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

-spec insert_listener(ets:tab(), [string()], pid()) -> true.
insert_listener(TID, Addrs, Pid) ->
    lists:foreach(fun(A) ->
                          insert_pid(TID, ?LISTENER, A, Pid)
                  end, Addrs),
    %% TODO: This was a convenient place to notify peerbook, but can
    %% we not do this here?
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:changed_listener(PeerBook),
    true.

-spec lookup_listener(ets:tab(), string()) -> {ok, pid()} | false.
lookup_listener(TID, Addr) ->
    lookup_pid(TID, ?LISTENER, Addr).

-spec remove_listener(ets:tab(), string()) -> true.
remove_listener(TID, Addr) ->
    remove_pid(TID, ?LISTENER, Addr),
    %% TODO: This was a convenient place to notify peerbook, but can
    %% we not do this here?
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:changed_listener(PeerBook),
    true.

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

-spec lookup_session(ets:tab(), string(), opts()) -> {ok, pid()} | false.
lookup_session(TID, Addr, Options) ->
    case get_opt(Options, unique_session, false) of
        %% Unique session, return that we don't know about the given
        %% session
        true -> false;
        false -> lookup_pid(TID, ?SESSION, Addr)
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

-spec lookup_stream_handlers(ets:tab()) -> [{string(), libp2p_session:stream_handler()}].
lookup_stream_handlers(TID) ->
    lookup_handlers(TID, ?STREAM_HANDLER).

-spec insert_stream_handler(ets:tab(), {string(), libp2p_session:stream_handler()}) -> true.
insert_stream_handler(TID, {Key, ServerMF}) ->
    ets:insert(TID, {{?STREAM_HANDLER, Key}, ServerMF}).
