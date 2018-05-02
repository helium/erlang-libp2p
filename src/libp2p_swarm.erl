-module(libp2p_swarm).

-export([start/1, start/2, stop/1, swarm/1, tid/1,
         opts/2, name/1, address/1, keys/1, peerbook/1,
         dial/3, dial/5, connect/2, connect/4,
         listen/2, listen_addrs/1,
         add_transport_handler/2,
         add_connection_handler/3,
         add_stream_handler/3, stream_handlers/1,
         register_session/3, register_listener/3,
         add_group/4,
         group_agent/1]).

-type swarm_opts() :: [swarm_opt()].
-type connect_opts() :: [connect_opt()].

-export_type([swarm_opts/0, connect_opts/0]).

-type swarm_opt() :: {key, {libp2p_crypto:public_key(), libp2p_crypto:sig_fun()}}
                   | {group_agent, atom()}
                   | {libp2p_transport_tcp, [libp2p_transport_tcp:opt()]}
                   | {libp2p_peerbook, [libp2p_peerbook:opt()]}
                   | {libp2p_yamux_stream, [libp2p_yamux_stream:opt()]}
                   | {libp2p_group_gossip, [libp2p_group_gossip:opt()]}.

-type connect_opt() :: {unique_session, boolean()}
                     | {unique_port, boolean()}.

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
    case supervisor:start_link(libp2p_swarm_sup, [Name, Opts]) of
        {ok, Pid} ->
            unlink(Pid),
            {ok, Pid};
        Other -> Other
    end.

%% @doc Stops the given swarm.
-spec stop(pid()) -> ok.
stop(Sup) ->
    Ref = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 ->
            error(timeout)
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
-spec address(ets:tab() | pid()) -> libp2p_crypto:address().
address(Sup) when is_pid(Sup) ->
    address(tid(Sup));
address(TID) ->
    libp2p_swarm_sup:address(TID).

%% @doc Get the public key and signing function for a swarm
-spec keys(ets:tab() | pid())
          -> {ok, libp2p_crypto:public_key(), libp2p_crypto:sig_fun()} | {error, term()}.
keys(Sup) when is_pid(Sup) ->
    keys(tid(Sup));
keys(TID) ->
    Server = libp2p_swarm_sup:server(TID),
    gen_server:call(Server, keys).

%% @doc Get the peerbook for a swarm.
-spec peerbook(ets:tab() | pid()) -> pid().
peerbook(Sup) when is_pid(Sup) ->
    peerbook(tid(Sup));
peerbook(TID) ->
    libp2p_swarm_sup:peerbook(TID).

%% @doc Get the options a swarm was started with.
-spec opts(ets:tab() | pid(), any()) -> swarm_opts() | any().
opts(Sup, Default) when is_pid(Sup) ->
    opts(tid(Sup), Default);
opts(TID, Default) ->
    libp2p_swarm_sup:opts(TID, Default).



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
                           start => {Transport, start_link, [TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            case supervisor:start_child(TransportSup, ChildSpec) of
                {error, Error} -> {error, Error};
                {ok, TransportPid} ->
                    libp2p_config:insert_transport(TID, Transport, TransportPid),
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
            case libp2p_config:lookup_listener(TID, Addr) of
                {ok, _} -> {error, already_listening};
                false ->
                    case Transport:start_listener(TransportPid, ListenAddr) of
                        {ok, TransportAddrs, ListenPid} ->
                            lager:info("Started Listener on ~p", [TransportAddrs]),
                            libp2p_config:insert_listener(TID, TransportAddrs, ListenPid),
                            register_listener(swarm(TID), TransportAddrs, ListenPid);
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
%% and monitored by the sware server.
-spec register_session(pid(), string(), pid()) -> ok.
register_session(Sup, Addr, SessionPid) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {register, libp2p_config:session(), [Addr], SessionPid}).

%% @private Register a session wih the swarm. This is used in `listen' a
%% started connection to be registered and monitored by the sware
%% server.
-spec register_listener(pid(), [string()], pid()) -> ok.
register_listener(Sup, ListenAddrs, SessionPid) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {register, libp2p_config:listener(), ListenAddrs, SessionPid}).


% Connect
%
-spec add_connection_handler(pid() | ets:tab(), string(),
                             {libp2p_transport:connection_handler(),
                              libp2p_transport:connection_handler()}) -> ok.
add_connection_handler(Sup, Key, {ServerMF, ClientMF}) when is_pid(Sup) ->
    add_connection_handler(tid(Sup), Key, {ServerMF, ClientMF});
add_connection_handler(TID, Key, {ServerMF, ClientMF}) ->
    libp2p_config:insert_connection_handler(TID, {Key, ServerMF, ClientMF}),
    ok.

-spec connect(pid(), string()) -> {ok, pid()} | {error, term()}.
connect(Sup, Addr) ->
    connect(Sup, Addr, [], ?CONNECT_TIMEOUT).

-spec connect(pid() | ets:tab(), string(), connect_opts(), pos_integer())
             -> {ok, pid()} | {error, term()}.
connect(Sup, Addr, Options, Timeout) when is_pid(Sup) ->
    connect(tid(Sup), Addr, Options, Timeout);
connect(TID, Addr, Options, Timeout) ->
    case libp2p_transport:connect_to(Addr, Options, Timeout, TID) of
        {error, Reason} -> {error, Reason};
        {ok, ConnAddr, SessionPid} ->
            register_session(swarm(TID), ConnAddr, SessionPid),
            {ok, SessionPid}
    end.


% Stream
%
-spec dial(pid(), string(), string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path) ->
    dial(Sup, Addr, Path, [], ?CONNECT_TIMEOUT).

-spec dial(pid(), string(), string(), connect_opts(), pos_integer())
          -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path, Options, Timeout) ->
    % e.g. dial(SID, "/ip4/127.0.0.1/tcp/5555", "echo")
    case connect(Sup, Addr, Options, Timeout) of
        {error, Error} -> {error, Error};
        {ok, SessionPid} ->libp2p_session:start_client_stream(Path, SessionPid)
    end.

-spec add_stream_handler(pid() | ets:tab(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Sup, Key, HandlerDef) when is_pid(Sup) ->
    add_stream_handler(tid(Sup), Key, HandlerDef);
add_stream_handler(TID, Key, HandlerDef) ->
    libp2p_config:insert_stream_handler(TID, {Key, HandlerDef}),
    ok.

-spec stream_handlers(pid() | ets:tab()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Sup) when is_pid(Sup) ->
    stream_handlers(tid(Sup));
stream_handlers(TID) ->
    libp2p_config:lookup_stream_handlers(TID).


%% Group
%%

-spec add_group(pid() | ets:tab(), GroupID::string(), Module::atom(), Args::[any()]) -> {ok, pid()} | {error, term()}.
add_group(Sup, GroupID, Module, Args) when is_pid(Sup) ->
    add_group(tid(Sup), GroupID, Module, Args);
add_group(TID, GroupID, Module, Args) ->
    case libp2p_config:lookup_group(TID, GroupID) of
        {ok, _Pid} -> ok;
        false ->
            GroupSup = libp2p_swarm_group_sup:sup(TID),
            ChildSpec = #{ id => GroupID,
                           start => {Module, start_link, [TID, GroupID, Args]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            case supervisor:start_child(GroupSup, ChildSpec) of
                {error, Error} -> {error, Error};
                {ok, GroupPid} ->
                    libp2p_config:insert_group(TID, GroupID, GroupPid),
                    {ok, GroupPid}
            end
    end.


%% Session Agent
%%

-spec group_agent(pid() | ets:tab()) -> pid().
group_agent(Sup) when is_pid(Sup) ->
    group_agent(tid(Sup));
group_agent(TID) ->
    libp2p_swarm_sup:group_agent(TID).
