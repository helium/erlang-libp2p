%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Config ==
%% Each swarm has an ETS table to store specific configs.
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_config).

-export([get_opt/2, get_opt/3,
         base_dir/1, swarm_dir/2,
         insert_pid/4, lookup_pid/3, lookup_pids/2, remove_pid/2, remove_pid/3,
         session/0, insert_session/3, lookup_session/2, lookup_session/3, remove_session/2,
         lookup_sessions/1, lookup_session_addrs/2, lookup_session_addrs/1,
         insert_session_addr_info/3, lookup_session_addr_info/2,
         transport/0, insert_transport/3, lookup_transport/2, lookup_transports/1,
         listen_addrs/1, listener/0, lookup_listener/2, insert_listener/3, remove_listener/2,
         listen_socket/0, lookup_listen_socket/2, lookup_listen_socket_by_addr/2, insert_listen_socket/4, remove_listen_socket/2, listen_sockets/1,
         lookup_connection_handlers/1, insert_connection_handler/2,
         lookup_stream_handlers/1, insert_stream_handler/2, remove_stream_handler/2,
         insert_group/3, lookup_group/2, remove_group/2,
         insert_relay/2, lookup_relay/1, remove_relay/1,
         insert_relay_stream/3, lookup_relay_stream/2, remove_relay_stream/2,
         insert_relay_sessions/3, lookup_relay_sessions/2, remove_relay_sessions/2,
         insert_proxy/2, lookup_proxy/1, remove_proxy/1,
         insert_nat/2, lookup_nat/1, remove_nat/1]).

-define(CONNECTION_HANDLER, connection_handler).
-define(STREAM_HANDLER, stream_handler).
-define(TRANSPORT, transport).
-define(SESSION, session).
-define(LISTENER, listener).
-define(LISTEN_SOCKET, listen_socket).
-define(GROUP, group).
-define(RELAY, relay).
-define(RELAY_STREAM, relay_stream).
-define(RELAY_SESSIONS, relay_sessions).
-define(PROXY, proxy).
-define(NAT, nat).
-define(ADDR_INFO, addr_info).

-type handler() :: {atom(), atom()}.
-type opts() :: [{atom(), any()}].

-export_type([opts/0]).

%%--------------------------------------------------------------------
%% @doc
%% Get opts (default value `undefined')
%% @end
%%--------------------------------------------------------------------
-spec get_opt(opts(), atom() | list()) -> undefined | {ok, any()}.
get_opt(Opts, L) when is_list(Opts), is_list(L)  ->
    get_opt_l(L, Opts);
get_opt(Opts, K) when is_list(Opts), is_atom(K) ->
    get_opt_l([K], Opts).

%%--------------------------------------------------------------------
%% @doc
%% Get opts
%% @end
%%--------------------------------------------------------------------
-spec get_opt(opts(), atom() | list(), any()) -> any().
get_opt(Opts, K, Default) ->
    case get_opt(Opts, K) of
        {ok, V}   -> V;
        undefined -> Default
    end.

%%--------------------------------------------------------------------
%% @doc
%% Get swarm base directory
%% @end
%%--------------------------------------------------------------------
-spec base_dir(ets:tab()) -> file:filename_all().
base_dir(TID) ->
    Opts = libp2p_swarm:opts(TID),
    get_opt(Opts, base_dir, "data").

%%--------------------------------------------------------------------
%% @doc
%% Get swarm directory
%% @end
%%--------------------------------------------------------------------
-spec swarm_dir(ets:tab(), [file:name_all()]) -> file:filename_all().
swarm_dir(TID, Names) ->
    FileName = filename:join([base_dir(TID), libp2p_swarm:name(TID) | Names]),
    ok = filelib:ensure_dir(FileName),
    FileName.

%%--------------------------------------------------------------------
%% @doc
%% Insert PID with `Kind' / `Ref' into config
%% @end
%%--------------------------------------------------------------------
-spec insert_pid(ets:tab(), atom(), term(), pid() | undefined) -> true.
insert_pid(TID, Kind, Ref, Pid) ->
    ets:insert(TID, {{Kind, Ref}, Pid}).

%%--------------------------------------------------------------------
%% @doc
%% Lookup PID by `Kind' / `Ref'
%% @end
%%--------------------------------------------------------------------
-spec lookup_pid(ets:tab(), atom(), term()) -> {ok, pid()} | false.
lookup_pid(TID, Kind, Ref) ->
    case ets:lookup(TID, {Kind, Ref}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% Lookup PIDs by `Kind'
%% @end
%%--------------------------------------------------------------------
-spec lookup_pids(ets:tab(), atom()) -> [{term(), pid()}].
lookup_pids(TID, Kind) ->
    [{Addr, Pid} || [Addr, Pid] <- ets:match(TID, {{Kind, '$1'}, '$2'})].

%%--------------------------------------------------------------------
%% @doc
%% Lookup Addresses by `Kind' \ `Pid'
%% @end
%%--------------------------------------------------------------------
-spec lookup_addrs(ets:tab(), atom(), pid()) -> [string()].
lookup_addrs(TID, Kind, Pid) ->
    [ Addr || [Addr] <- ets:match(TID, {{Kind, '$1'}, Pid})].

%%--------------------------------------------------------------------
%% @doc
%% Lookup Addresses by `Kind'
%% @end
%%--------------------------------------------------------------------
-spec lookup_addrs(ets:tab(), atom()) -> [string()].
lookup_addrs(TID, Kind) ->
    [ Addr || [Addr] <- ets:match(TID, {{Kind, '$1'}, '_'})].

%%--------------------------------------------------------------------
%% @doc
%% Remove PID by `Kind' / `Ref'
%% @end
%%--------------------------------------------------------------------
-spec remove_pid(ets:tab(), atom(), term()) -> true.
remove_pid(TID, Kind, Ref) ->
    ets:delete(TID, {Kind, Ref}).

%%--------------------------------------------------------------------
%% @doc
%% Remove PID
%% @end
%%--------------------------------------------------------------------
-spec remove_pid(ets:tab(), pid()) -> true.
remove_pid(TID, Pid) ->
    ets:match_delete(TID, {'_', Pid}).

%%--------------------------------------------------------------------
%% @doc
%% Lookup handlers
%% @end
%%--------------------------------------------------------------------
-spec lookup_handlers(ets:tab(), atom()) -> [{term(), any()}].
lookup_handlers(TID, TableKey) ->
    [ {Key, Handler} ||
        [Key, Handler] <- ets:match(TID, {{TableKey, '$1'}, '$2'})].

%%--------------------------------------------------------------------
%% @doc
%% Return tranport kind
%% @end
%%--------------------------------------------------------------------
-spec transport() -> ?TRANSPORT.
transport() ->
    ?TRANSPORT.

%%--------------------------------------------------------------------
%% @doc
%% Insert transport by `Module'
%% @end
%%--------------------------------------------------------------------
-spec insert_transport(ets:tab(), atom(), pid() | undefined) -> true.
insert_transport(TID, Module, Pid) ->
    insert_pid(TID, ?TRANSPORT, Module, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup transport by `Module'
%% @end
%%--------------------------------------------------------------------
-spec lookup_transport(ets:tab(), atom()) -> {ok, pid()} | false.
lookup_transport(TID, Module) ->
    lookup_pid(TID, ?TRANSPORT, Module).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all transports
%% @end
%%--------------------------------------------------------------------
-spec lookup_transports(ets:tab()) -> [{term(), pid()}].
lookup_transports(TID) ->
    lookup_pids(TID, ?TRANSPORT).

%%--------------------------------------------------------------------
%% @doc
%% Return listener kind
%% @end
%%--------------------------------------------------------------------
-spec listener() -> ?LISTENER.
listener() ->
    ?LISTENER.

%%--------------------------------------------------------------------
%% @doc
%% Insert listener by `Addresses'
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc
%% Lookup listener by `Address'
%% @end
%%--------------------------------------------------------------------
-spec lookup_listener(ets:tab(), string()) -> {ok, pid()} | false.
lookup_listener(TID, Addr) ->
    lookup_pid(TID, ?LISTENER, Addr).

%%--------------------------------------------------------------------
%% @doc
%% Remove listener by `Address'
%% @end
%%--------------------------------------------------------------------
-spec remove_listener(ets:tab(), string()) -> true.
remove_listener(TID, Addr) ->
    remove_pid(TID, ?LISTENER, Addr),
    %% TODO: This was a convenient place to notify peerbook, but can
    %% we not do this here?
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:changed_listener(PeerBook),
    true.

%%--------------------------------------------------------------------
%% @doc
%% Lookup all listener addresses
%% @end
%%--------------------------------------------------------------------
-spec listen_addrs(ets:tab()) -> [string()].
listen_addrs(TID) ->
    [ Addr || [Addr] <- ets:match(TID, {{?LISTENER, '$1'}, '_'})].

%%--------------------------------------------------------------------
%% @doc
%% Return listen socket kind
%% @end
%%--------------------------------------------------------------------
-spec listen_socket() -> ?LISTEN_SOCKET.
listen_socket() ->
    ?LISTEN_SOCKET.

%%--------------------------------------------------------------------
%% @doc
%% Insert listen socket
%% @end
%%--------------------------------------------------------------------
-spec insert_listen_socket(ets:tab(), pid(), string(), gen_tcp:socket()) -> true.
insert_listen_socket(TID, Pid, ListenAddr, Socket) ->
    ets:insert(TID, {{?LISTEN_SOCKET, Pid}, {ListenAddr, Socket}}),
    true.

%%--------------------------------------------------------------------
%% @doc
%% Lookup listen socket by `Pid'
%% @end
%%--------------------------------------------------------------------
-spec lookup_listen_socket(ets:tab(), pid()) -> {ok, {string(), gen_tcp:socket()}} | false.
lookup_listen_socket(TID, Pid) ->
    case ets:lookup(TID, {?LISTEN_SOCKET, Pid}) of
        [{_, Sock}] -> {ok, Sock};
        [] -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% Lookup listen socket by `Address'
%% @end
%%--------------------------------------------------------------------
-spec lookup_listen_socket_by_addr(ets:tab(), string()) -> {ok, {pid(), gen_tcp:socket()}} | false.
lookup_listen_socket_by_addr(TID, Addr) ->
    case ets:match(TID, {{?LISTEN_SOCKET, '$1'}, {Addr, '$2'}}) of
        [[Pid, Socket]] ->
            {ok, {Pid, Socket}};
        [] ->
            false
    end.

%%--------------------------------------------------------------------
%% @doc
%% Remove listen socket by `Pid'
%% @end
%%--------------------------------------------------------------------
-spec remove_listen_socket(ets:tab(), pid()) -> true.
remove_listen_socket(TID, Pid) ->
    ets:delete(TID, {?LISTEN_SOCKET, Pid}),
    true.

%%--------------------------------------------------------------------
%% @doc
%% Lookup all listen sockets
%% @end
%%--------------------------------------------------------------------
-spec listen_sockets(ets:tab()) -> [{pid(), string(), gen_tcp:socket()}].
listen_sockets(TID) ->
    [{Pid, Addr, Socket} || [Pid, Addr, Socket] <- ets:match(TID, {{?LISTEN_SOCKET, '$1'}, {'$2', '$3'}})].

%%--------------------------------------------------------------------
%% @doc
%% Return session kind
%% @end
%%--------------------------------------------------------------------
-spec session() -> ?SESSION.
session() ->
    ?SESSION.

%%--------------------------------------------------------------------
%% @doc
%% Insert session
%% @end
%%--------------------------------------------------------------------
-spec insert_session(ets:tab(), string(), pid()) -> true.
insert_session(TID, Addr, Pid) ->
    insert_pid(TID, ?SESSION, Addr, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup session by `address'
%% @end
%%--------------------------------------------------------------------
-spec lookup_session(ets:tab(), string(), opts()) -> {ok, pid()} | false.
lookup_session(TID, Addr, Options) ->
    case get_opt(Options, unique_session, false) of
        %% Unique session, return that we don't know about the given
        %% session
        true -> false;
        false -> lookup_pid(TID, ?SESSION, Addr)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Lookup session by `address'
%% @end
%%--------------------------------------------------------------------
-spec lookup_session(ets:tab(), string()) -> {ok, pid()} | false.
lookup_session(TID, Addr) ->
    lookup_session(TID, Addr, []).

%%--------------------------------------------------------------------
%% @doc
%% Remove session by `address'
%% @end
%%--------------------------------------------------------------------
-spec remove_session(ets:tab(), string()) -> true.
remove_session(TID, Addr) ->
    remove_pid(TID, ?SESSION, Addr).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all sessions
%% @end
%%--------------------------------------------------------------------
-spec lookup_sessions(ets:tab()) -> [{term(), pid()}].
lookup_sessions(TID) ->
    lookup_pids(TID, ?SESSION).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all session addresses by `Pid'
%% @end
%%--------------------------------------------------------------------
-spec lookup_session_addrs(ets:tab(), pid()) -> [string()].
lookup_session_addrs(TID, Pid) ->
    lookup_addrs(TID, ?SESSION, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all session addresses
%% @end
%%--------------------------------------------------------------------
-spec lookup_session_addrs(ets:tab()) -> [string()].
lookup_session_addrs(TID) ->
    lookup_addrs(TID, ?SESSION).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all session address info by `Pid'
%% @end
%%--------------------------------------------------------------------
-spec lookup_session_addr_info(ets:tab(), pid()) -> {ok, {string(), string()}} | false.
lookup_session_addr_info(TID, Pid) ->
    lookup_addr_info(TID, ?SESSION, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Insert session address info
%% @end
%%--------------------------------------------------------------------
-spec insert_session_addr_info(ets:tab(), pid(), {string(), string()}) -> true.
insert_session_addr_info(TID, Pid, AddrInfo) ->
    insert_addr_info(TID, ?SESSION, Pid, AddrInfo).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all connection handlers
%% @end
%%--------------------------------------------------------------------
-spec lookup_connection_handlers(ets:tab()) -> [{string(), {handler(), handler() | undefined}}].
lookup_connection_handlers(TID) ->
    lookup_handlers(TID, ?CONNECTION_HANDLER).

%%--------------------------------------------------------------------
%% @doc
%% Insert connection handler
%% @end
%%--------------------------------------------------------------------
-spec insert_connection_handler(ets:tab(), {string(), handler(), handler() | undefined}) -> true.
insert_connection_handler(TID, {Key, ServerMF, ClientMF}) ->
    ets:insert(TID, {{?CONNECTION_HANDLER, Key}, {ServerMF, ClientMF}}).

%%--------------------------------------------------------------------
%% @doc
%% Lookup all stream handlers
%% @end
%%--------------------------------------------------------------------
-spec lookup_stream_handlers(ets:tab()) -> [{string(), libp2p_session:stream_handler()}].
lookup_stream_handlers(TID) ->
    lookup_handlers(TID, ?STREAM_HANDLER).

%%--------------------------------------------------------------------
%% @doc
%% Insert stream handler
%% @end
%%--------------------------------------------------------------------
-spec insert_stream_handler(ets:tab(), {string(), libp2p_session:stream_handler()}) -> true.
insert_stream_handler(TID, {Key, ServerMF}) ->
    ets:insert(TID, {{?STREAM_HANDLER, Key}, ServerMF}).

%%--------------------------------------------------------------------
%% @doc
%% Remove stream handler
%% @end
%%--------------------------------------------------------------------
-spec remove_stream_handler(ets:tab(), string()) -> true.
remove_stream_handler(TID, Key) ->
    ets:delete(TID, {?STREAM_HANDLER, Key}).

%%--------------------------------------------------------------------
%% @doc
%% Insert group
%% @end
%%--------------------------------------------------------------------
-spec insert_group(ets:tab(), string(), pid()) -> true.
insert_group(TID, GroupID, Pid) ->
    insert_pid(TID, ?GROUP, GroupID, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup group by `GroupID'
%% @end
%%--------------------------------------------------------------------
-spec lookup_group(ets:tab(), string()) -> {ok, pid()} | false.
lookup_group(TID, GroupID) ->
    lookup_pid(TID, ?GROUP, GroupID).

%%--------------------------------------------------------------------
%% @doc
%% Remove group by `GroupID'
%% @end
%%--------------------------------------------------------------------
-spec remove_group(ets:tab(), string()) -> true.
remove_group(TID, GroupID) ->
    remove_pid(TID, ?GROUP, GroupID).

%%--------------------------------------------------------------------
%% @doc
%% Insert relay
%% @end
%%--------------------------------------------------------------------
-spec insert_relay(ets:tab(), pid()) -> true.
insert_relay(TID, Pid) ->
    insert_pid(TID, ?RELAY, "pid", Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup relay
%% @end
%%--------------------------------------------------------------------
-spec lookup_relay(ets:tab()) -> {ok, pid()} | false.
lookup_relay(TID) ->
    lookup_pid(TID, ?RELAY, "pid").

%%--------------------------------------------------------------------
%% @doc
%% Remove relay
%% @end
%%--------------------------------------------------------------------
-spec remove_relay(ets:tab()) -> true.
remove_relay(TID) ->
    remove_pid(TID, ?RELAY, "pid").

%%--------------------------------------------------------------------
%% @doc
%% Insert relay stream
%% @end
%%--------------------------------------------------------------------
-spec insert_relay_stream(ets:tab(), string(), pid()) -> true.
insert_relay_stream(TID, Address, Pid) ->
    insert_pid(TID, ?RELAY_STREAM, Address, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup relay stream by `Address'
%% @end
%%--------------------------------------------------------------------
-spec lookup_relay_stream(ets:tab(), string()) -> {ok, pid()} | false.
lookup_relay_stream(TID, Address) ->
    lookup_pid(TID, ?RELAY_STREAM, Address).

%%--------------------------------------------------------------------
%% @doc
%% Remove relay stream by `Address'
%% @end
%%--------------------------------------------------------------------
-spec remove_relay_stream(ets:tab(), string()) -> true.
remove_relay_stream(TID, Address) ->
    remove_pid(TID, ?RELAY_STREAM, Address).

%%--------------------------------------------------------------------
%% @doc
%% Insert relay sessions
%% @end
%%--------------------------------------------------------------------
-spec insert_relay_sessions(ets:tab(), string(), pid()) -> true.
insert_relay_sessions(TID, Address, Pid) ->
    insert_pid(TID, ?RELAY_SESSIONS, Address, Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup relay sessions by `Address'
%% @end
%%--------------------------------------------------------------------
-spec lookup_relay_sessions(ets:tab(), string()) -> {ok, pid()} | false.
lookup_relay_sessions(TID, Address) ->
    lookup_pid(TID, ?RELAY_SESSIONS, Address).

%%--------------------------------------------------------------------
%% @doc
%% Remove relay sessions by `Address'
%% @end
%%--------------------------------------------------------------------
-spec remove_relay_sessions(ets:tab(), string()) -> true.
remove_relay_sessions(TID, Address) ->
    remove_pid(TID, ?RELAY_SESSIONS, Address).

%%--------------------------------------------------------------------
%% @doc
%% Insert proxy
%% @end
%%--------------------------------------------------------------------
-spec insert_proxy(ets:tab(), pid()) -> true.
insert_proxy(TID, Pid) ->
    insert_pid(TID, ?PROXY, "pid", Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup proxy
%% @end
%%--------------------------------------------------------------------
-spec lookup_proxy(ets:tab()) -> {ok, pid()} | false.
lookup_proxy(TID) ->
    lookup_pid(TID, ?PROXY, "pid").

%%--------------------------------------------------------------------
%% @doc
%% Remove proxy
%% @end
%%--------------------------------------------------------------------
-spec remove_proxy(ets:tab()) -> true.
remove_proxy(TID) ->
    remove_pid(TID, ?PROXY, "pid").

%%--------------------------------------------------------------------
%% @doc
%% Insert NAT
%% @end
%%--------------------------------------------------------------------
-spec insert_nat(ets:tab(), pid()) -> true.
insert_nat(TID, Pid) ->
    insert_pid(TID, ?NAT, "pid", Pid).

%%--------------------------------------------------------------------
%% @doc
%% Lookup NAT
%% @end
%%--------------------------------------------------------------------
-spec lookup_nat(ets:tab()) -> {ok, pid()} | false.
lookup_nat(TID) ->
    lookup_pid(TID, ?NAT, "pid").

%%--------------------------------------------------------------------
%% @doc
%% Remove NAT
%% @end
%%--------------------------------------------------------------------
-spec remove_nat(ets:tab()) -> true.
remove_nat(TID) ->
    remove_pid(TID, ?NAT, "pid").

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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

-spec insert_addr_info(ets:tab(), atom(), pid(), {string(), string()}) -> true.
insert_addr_info(TID, Kind, Pid, AddrInfo) ->
    %% Insert in the form that remove_pid understands to ensure that
    %% addr info gets removed for removed pids regardless of what kind
    %% of addr_info it is
    ets:insert(TID, {{?ADDR_INFO, Kind, AddrInfo}, Pid}).

-spec lookup_addr_info(ets:tab(), atom(), pid()) -> {ok, {string(), string()}} | false.
lookup_addr_info(TID, Kind, Pid) ->
    case ets:match(TID, {{?ADDR_INFO, Kind, '$1'}, Pid}) of
        [[AddrInfo]]  -> {ok, AddrInfo};
        [] -> false
    end.
