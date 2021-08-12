-module(libp2p_swarm).

-export([start/1, start/2, stop/1, is_stopping/1, swarm/1, tid/1,
         opts/1, name/1, pubkey_bin/1, p2p_address/1, keys/1,
         network_id/2, network_id/1,
         store_peerbook/2, peerbook/1, peerbook_pid/1, cache/1, sessions/1,
         dial/3, dial/5, connect/2, connect/4,
         dial_framed_stream/5, dial_framed_stream/7,
         listen/2, listen_addrs/1,
         add_transport_handler/2,
         add_connection_handler/3,
         add_stream_handler/3, remove_stream_handler/2, stream_handlers/1,
         register_session/2, register_listener/2,
         add_group/4, remove_group/2,
         gossip_group/1,
         reg_name_from_tid/2]).

-type swarm_opts() :: [swarm_opt()].
-type connect_opts() :: [connect_opt()].

-export_type([swarm_opts/0, connect_opts/0]).

-type swarm_opt() :: {key, {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun()}}
                   | {base_dir, string()}
                   | {libp2p_transport_tcp, [libp2p_transport_tcp:opt()]}
                   | {libp2p_peerbook, [libp2p_peerbook:opt()]}
                   | {libp2p_yamux_stream, [libp2p_yamux_stream:opt()]}
                   | {libp2p_group_gossip, [libp2p_group_gossip:opt()]}
                   | {libp2p_nat, [libp2p_nat:opt()]}
                   | {libp2p_proxy, [libp2p_proxy:opt()]}.

-type connect_opt() :: {unique_session, boolean()}
                     | {unique_port, boolean()}
                     | no_relay | {no_relay, boolean()}.

-define(CONNECT_TIMEOUT, 5000).

%% @doc Starts a swarm with a given name. This starts a swarm with no
%% listeners. The swarm name is used to distinguish the data folder
%% for the swarm from other started swarms on the same node.
-spec start(atom()) -> {ok, pid()} | ignore | {error, term()}.
start(Name) when is_atom(Name) ->
    start(Name, []).

%% @doc Starts a swarm with a given name and sarm options. This starts
%% a swarm with no listeners. The options can be used to configure and
%% control behavior of various subsystems of the swarm.
-spec start(atom(), swarm_opts()) -> {ok, pid()} | ignore | {error, term()}.
start(Name, Opts)  ->
    RegName = list_to_atom(atom_to_list(libp2p_swarm_sup) ++ "_" ++ atom_to_list(Name)),
    SideJobRegName = list_to_atom(atom_to_list(libp2p_swarm_sidejob_sup) ++ "_" ++ atom_to_list(Name)),
    {ok, _} = application:ensure_all_started(sidejob),
    sidejob:new_resource(SideJobRegName, sidejob_supervisor, application:get_env(libp2p, sidejob_limit, 15000)),
    case supervisor:start_link({local,RegName}, libp2p_swarm_sup, [Name, Opts]) of
        {ok, Pid} ->
            unlink(Pid),
            {ok, Pid};
        Other -> Other
    end.

%% @doc returns an atom to be used as the registered name of a process
-spec reg_name_from_tid(ets:tab(), atom()) -> atom().
reg_name_from_tid(TID, Module)->
    list_to_atom(atom_to_list(Module) ++ "_" ++ atom_to_list(name(TID))).


%% @doc Stops the given swarm.
-spec stop(pid()) -> ok.
stop(Sup) ->
    TID = tid(Sup),
    ets:insert(TID, {shutdown, true}),
    Ref = erlang:monitor(process, Sup),
    %% do normal stops for everything that owns a rocks or dets instance
    ok = libp2p_cache:stop(TID),
    ok = libp2p_peerbook:stop(TID),
    ok = libp2p_group_mgr:stop_all(TID),

    %% simulate supervisor shutdown, this should probably be a simple_one_for_one
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 10000 ->
            error(timeout)
    end.

is_stopping(Sup) when is_pid(Sup) ->
    try
        is_stopping(tid(Sup))
    catch
        exit:{noproc, _} -> true
    end;
is_stopping(TID) ->
    try
         case ets:lookup(TID, shutdown) of
             [] -> false;
             _ -> true
         end
    catch
        exit:{noproc, _} -> true
    end.


% Access
%

%% @doc Get the swarm for a given ets table. A swarm is represented by
%% the supervisor for the services it contains. Many internal
%% processes get started with the ets table that stores data about a
%% swarm. This function makes it easy to get back to the swarm from a
%% given swarm ets table.
-spec swarm(ets:tab()) -> pid().
swarm(TID) ->
    libp2p_swarm_sup:sup(TID).

%% @doc Gets the ets table for for this swarm. This is the opposite of
%% swarm/1 and used by a number of internal swarm functions and
%% services to find other services in the given swarm.
-spec tid(pid()) -> ets:tab().
tid(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, tid).

%% @doc Get the name for a swarm.
-spec name(ets:tab() | pid()) -> atom().
name(Sup) when is_pid(Sup) ->
    name(tid(Sup));
name(TID) ->
    libp2p_swarm_sup:name(TID).

%% @doc Get cryptographic address for a swarm.
-spec pubkey_bin(ets:tab() | pid()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(Sup) when is_pid(Sup) ->
    pubkey_bin(tid(Sup));
pubkey_bin(TID) ->
    libp2p_swarm_sup:pubkey_bin(TID).

%% @doc Get the p2p address in string form for a swarm
-spec p2p_address(ets:tab() | pid()) -> string().
p2p_address(TidOrPid) ->
    libp2p_crypto:pubkey_bin_to_p2p(pubkey_bin(TidOrPid)).

%% @doc Get the public key and signing function for a swarm
-spec keys(ets:tab() | pid()) -> {ok, libp2p_crypto:pubkey(), libp2p_crypto:sig_fun(), libp2p_crypto:ecdh_fun()} | {error, term()}.
keys(Sup) when is_pid(Sup) ->
    keys(tid(Sup));
keys(TID) ->
    Server = libp2p_swarm_sup:server(TID),
    gen_server:call(Server, keys).

-spec network_id(ets:tab() | pid(), binary()) -> true.
network_id(Sup, NetworkID) when is_pid(Sup) ->
    network_id(tid(Sup), NetworkID);
network_id(TID, NetworkID) ->
    ets:insert(TID, {network_id, NetworkID}).

-spec network_id(ets:tab() | pid()) -> binary() | undefined.
network_id(Sup) when is_pid(Sup) ->
    network_id(tid(Sup));
network_id(TID) ->
    case ets:lookup(TID, network_id) of
        [{network_id, ID}] -> ID;
        [] -> undefined
    end.

%% @doc get the peerbook db handle for a swarm
-spec peerbook(ets:tab() | pid()) -> libp2p_peerbook:peerbook() | false.
peerbook(Sup) when is_pid(Sup) ->
    peerbook(tid(Sup));
peerbook(TID) ->
    case ets:lookup(TID, peerbook_db) of
        [{peerbook_db, DB}] -> DB;
        [] -> false
    end.

-spec store_peerbook(ets:tab() | pid(), libp2p_peerbook:peerbook()) -> true.
store_peerbook(Sup, Handle) when is_pid(Sup) ->
    store_peerbook(tid(Sup), Handle);
store_peerbook(TID, Handle) ->
    ets:insert(TID, {peerbook_db, Handle}).

%% @doc Get the peerbook pid for a swarm.
-spec peerbook_pid(ets:tab() | pid()) -> pid().
peerbook_pid(Sup) when is_pid(Sup) ->
    peerbook_pid(tid(Sup));
peerbook_pid(TID) ->
    libp2p_swarm_sup:peerbook(TID).

%% @doc Get the cache for a swarm.
-spec cache(ets:tab() | pid()) -> pid().
cache(Sup) when is_pid(Sup) ->
    cache(tid(Sup));
cache(TID) ->
    libp2p_swarm_auxiliary_sup:cache(TID).

%% @doc Get the options a swarm was started with.
-spec opts(ets:tab() | pid()) -> swarm_opts() | any().
opts(Sup) when is_pid(Sup) ->
    opts(tid(Sup));
opts(TID) ->
    libp2p_swarm_sup:opts(TID).


%% @doc Get a list of libp2p_session addresses and pids for all open
%% sessions to remote peers.
-spec sessions(ets:tab() | pid()) -> [{string(), pid()}].
sessions(Sup) when is_pid(Sup) ->
    sessions(tid(Sup));
sessions(TID) ->
    libp2p_config:lookup_sessions(TID).

% Transport
%

-spec add_transport_handler(pid() | ets:tab(), atom())-> ok | {error, term()}.
add_transport_handler(Sup, Transport) when is_pid(Sup) ->
    add_transport_handler(tid(Sup), Transport);
add_transport_handler(TID, Transport) ->
    case libp2p_config:lookup_transport(TID, Transport) of
        {ok, _Pid} -> ok;
        false ->
            TransportSup = libp2p_swarm_transport_sup:sup(TID),
            ChildSpec = #{ id => Transport,
                           start => {libp2p_transport, start_link, [Transport, TID]},
                           restart => transient,
                           shutdown => 5000,
                           type => worker },
            case supervisor:start_child(TransportSup, ChildSpec) of
                {error, Error} -> {error, Error};
                {ok, _TransportPid} ->
                    ok
            end
    end.


% Listen
%

-spec listen(pid() | ets:tab(), string() | non_neg_integer()) -> ok | {error, term()}.
listen(Sup, Port) when is_integer(Port)->
    listen(Sup, "/ip4/0.0.0.0/tcp/" ++ integer_to_list(Port));
listen(Sup, Addr) when is_pid(Sup) ->
    listen(tid(Sup), Addr);
listen(TID, Addr) ->
    case libp2p_transport:for_addr(TID, Addr) of
        {ok, ListenAddr, {Transport, TransportPid}} ->
            case libp2p_config:lookup_listen_socket_by_addr(TID, Addr) of
                {ok, _} -> {error, already_listening};
                false ->
                    case Transport:start_listener(TransportPid, ListenAddr) of
                        {ok, TransportAddrs, ListenPid} ->
                            lager:info("Started Listener on ~p", [TransportAddrs]),
                            register_listener(swarm(TID), ListenPid);
                        {error, Error={{shutdown, _}, _}} ->
                            % We don't log shutdown errors to avoid cluttering the logs
                            % with confusing messages.
                            {error, Error};
                        {error, Error} ->
                            lager:error("Failed to start listener on ~p: ~p", [ListenAddr, Error]),
                            {error, Error}
                    end
            end;
        {error, Reason} -> {error, Reason}
    end.

-spec listen_addrs(pid() | ets:tab()) -> [string()].
listen_addrs(Sup) when is_pid(Sup) ->
    listen_addrs(tid(Sup));
listen_addrs(TID) ->
    libp2p_config:listen_addrs(TID).

%% @private Register a session wih the swarm. This is used in
%% start_server_session to get an accepted connection to be registered
%% and monitored by the swarm server.
-spec register_session(pid(), pid()) -> ok.
register_session(Sup, SessionPid) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {register, libp2p_config:session(), SessionPid}).

%% @private Register a session wih the swarm. This is used in `listen' a
%% started connection to be registered and monitored by the sware
%% server.
-spec register_listener(pid(), pid()) -> ok.
register_listener(Sup, SessionPid) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {register, libp2p_config:listener(), SessionPid}).


% Connect
%
-spec add_connection_handler(pid() | ets:tab(), string(),
                             {libp2p_transport:connection_handler(),
                              libp2p_transport:connection_handler() | undefined}) -> ok.
add_connection_handler(Sup, Key, {ServerMF, ClientMF}) when is_pid(Sup) ->
    add_connection_handler(tid(Sup), Key, {ServerMF, ClientMF});
add_connection_handler(TID, Key, {ServerMF, ClientMF}) ->
    libp2p_config:insert_connection_handler(TID, {Key, ServerMF, ClientMF}),
    ok.

-spec connect(pid() | ets:tab(), string()) -> {ok, pid()} | {error, term()}.
connect(Sup, Addr) ->
    connect(Sup, Addr, [], ?CONNECT_TIMEOUT).

-spec connect(pid() | ets:tab(), string(), connect_opts(), pos_integer())
             -> {ok, pid()} | {error, term()}.
connect(Sup, Addr, Options, Timeout) when is_pid(Sup) ->
    connect(tid(Sup), Addr, Options, Timeout);
connect(TID, Addr, Options, Timeout) ->
    libp2p_transport:connect_to(Addr, Options, Timeout, TID).


% Stream
%
-spec dial(pid() | ets:tab(), string(), string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path) when is_pid(Sup) ->
    dial(tid(Sup), Addr, Path);
dial(TID, Addr, Path) ->
    dial(TID, Addr, Path, [], ?CONNECT_TIMEOUT).


-spec dial(pid() | ets:tab(), string(), string(), connect_opts(), pos_integer())
          -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path, Options, Timeout) when is_pid(Sup) ->
    dial(tid(Sup), Addr, Path, Options, Timeout);
dial(TID, Addr, Path, Options, Timeout) ->
    % e.g. dial(SID, "/ip4/127.0.0.1/tcp/5555", "echo")
    case connect(TID, Addr, Options, Timeout) of
        {error, Error} -> {error, Error};
        {ok, SessionPid} -> libp2p_session:dial(Path, SessionPid)
    end.


%% @doc Dial a remote swarm, negotiate a path and start a framed
%% stream client with the given Module as the handler.
-spec dial_framed_stream(pid() | ets:tab(), Addr::string(), Path::string(),
                         Module::atom(), Args::[any()])
                        -> {ok, pid()} | {error, term()}.
dial_framed_stream(Sup, Addr, Path, Module, Args) when is_pid(Sup) ->
    dial_framed_stream(tid(Sup), Addr, Path, Module, Args);
dial_framed_stream(TID, Addr, Path, Module, Args) ->
    dial_framed_stream(TID, Addr, Path, [], ?CONNECT_TIMEOUT, Module, Args).

-spec dial_framed_stream(pid() | ets:tab(), Addr::string(), Path::string(), connect_opts(),
                         Timeout::pos_integer(), Module::atom(), Args::[any()])
                        -> {ok, pid()} | {error, term()}.
dial_framed_stream(Sup, Addr, Path, Options, Timeout, Module, Args) when is_pid(Sup) ->
    dial_framed_stream(tid(Sup), Addr, Path, Options, Timeout, Module, Args);
dial_framed_stream(TID, Addr, Path, Options, Timeout, Module, Args) ->
    case proplists:get_value(secured, Args, false) of
        false ->
            case connect(TID, Addr, Options, Timeout) of
                {error, Error} ->
                    {error, Error};
                {ok, SessionPid} ->
                    libp2p_session:dial_framed_stream(Path, SessionPid, Module, Args)
            end;
        _Swarm when is_pid(_Swarm) ->
            case libp2p_transport_p2p:p2p_addr(Addr) of
                {error, _} ->
                    {error, secured_not_dialing_p2p};
                {ok, _} ->
                    case connect(TID, Addr, Options, Timeout) of
                        {error, Error} ->
                            {error, Error};
                        {ok, SessionPid} ->
                            libp2p_session:dial_framed_stream(Path, SessionPid, Module, Args ++ [{secure_peer, libp2p_crypto:p2p_to_pubkey_bin(Addr)}])
                    end
            end
    end.

-spec add_stream_handler(pid() | ets:tab(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Sup, Key, HandlerDef) when is_pid(Sup) ->
    add_stream_handler(tid(Sup), Key, HandlerDef);
add_stream_handler(TID, Key, HandlerDef) ->
    libp2p_config:insert_stream_handler(TID, {Key, HandlerDef}),
    ok.

-spec remove_stream_handler(pid() | ets:tab(), string()) -> ok.
remove_stream_handler(Sup, Key) when is_pid(Sup) ->
    remove_stream_handler(tid(Sup), Key);
remove_stream_handler(TID, Key) ->
    libp2p_config:remove_stream_handler(TID, Key),
    ok.

-spec stream_handlers(pid() | ets:tab()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Sup) when is_pid(Sup) ->
    stream_handlers(tid(Sup));
stream_handlers(TID) ->
    libp2p_config:lookup_stream_handlers(TID).


%% Group
%%

-spec add_group(pid() | ets:tab(), GroupID::string(), Module::atom(), Args::[any()])
               -> {ok, pid()} | {error, term()}.
add_group(Sup, GroupID, Module, Args) when is_pid(Sup) ->
    add_group(tid(Sup), GroupID, Module, Args);
add_group(TID, GroupID, Module, Args) ->
    Mgr = libp2p_group_mgr:mgr(TID),
    libp2p_group_mgr:add_group(Mgr, GroupID, Module, Args).

-spec remove_group(pid() | ets:tab(), GroupID::string()) -> ok | {error, term()}.
remove_group(Sup, GroupID) when is_pid(Sup) ->
    remove_group(tid(Sup), GroupID);
remove_group(TID, GroupID) ->
    Mgr = libp2p_group_mgr:mgr(TID),
    libp2p_group_mgr:remove_group(Mgr, GroupID).

%% Gossip Group
%%

-spec gossip_group(pid() | ets:tab()) -> pid().
gossip_group(Sup) when is_pid(Sup) ->
    gossip_group(tid(Sup));
gossip_group(TID) ->
    libp2p_swarm_sup:gossip_group(TID).
