-module(libp2p_swarm).

-export([start/1, start/2, stop/1, swarm/1,
         opts/2, name/1, address/1, keys/1, peerbook/1,
         dial/3, dial/5, connect/2, connect/4,
         listen/2, listen_addrs/1,
         add_transport_handler/2,
         add_connection_handler/3,
         add_stream_handler/3, stream_handlers/1]).

-type connect_opt() :: {unique_session, true | false}
                     | {unique_port, true | false}.

-type swarm_opts() :: [swarm_opt()].
-export_type([swarm_opts/0]).

-type swarm_opt() :: {key, {libp2p_crypto:public_key(), libp2p_crypto:sig_fun()}}
                   | {listen_opts, [listen_opt()]}
                   | {peerbook, [peerbook_opt()]}
                   | {yamux, [yamux_opt()]}.

-type listen_opt() :: {tcp, tcp_listen_opt()}
                    | {max_connections, pos_integer()}.

-type tcp_listen_opt() :: {backlog, non_neg_integer()}
                        | {buffer, non_neg_integer()}
                        | {delay_send, boolean()}
                        | {dontroute, boolean()}
                        | {exit_on_close, boolean()}
                        | {fd, non_neg_integer()}
                        | {high_msgq_watermark, non_neg_integer()}
                        | {high_watermark, non_neg_integer()}
                        | {keepalive, boolean()}
                        | {linger, {boolean(), non_neg_integer()}}
                        | {low_msgq_watermark, non_neg_integer()}
                        | {low_watermark, non_neg_integer()}
                        | {nodelay, boolean()}
                        | {port, inet:port_number()}
                        | {priority, integer()}
                        | {raw, non_neg_integer(), non_neg_integer(), binary()}
                        | {recbuf, non_neg_integer()}
                        | {send_timeout, timeout()}
                        | {send_timeout_close, boolean()}
                        | {sndbuf, non_neg_integer()}
                        | {tos, integer()}.

-type peerbook_opt() :: {stale_time, pos_integer()}.

-type yamux_opt() :: {max_window, pos_integer()}.

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
    exit(Sup, normal),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 ->
            error(timeout)
    end.

% Access
%

-spec swarm(ets:tab()) -> supervisor:sup_ref().
swarm(TID) ->
    libp2p_swarm_sup:sup(TID).

%% @doc Get the name for a swarm.
-spec name(ets:tab() | pid()) -> atom().
name(Sup) when is_pid(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, name);
name(TID) ->
    libp2p_swarm_sup:name(TID).

%% @doc Get cryptographic address for a swarm.
-spec address(ets:tab() | pid()) -> libp2p_crypto:address().
address(Sup) when is_pid(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, address);
address(TID) ->
    libp2p_swarm_sup:address(TID).

%% @doc Get the public key and signing function for a swarm
-spec keys(ets:tab() | pid())
          -> {ok, libp2p_crypto:public_key(), libp2p_crypto:sig_fun()} | {error, term()}.
keys(Sup) when is_pid(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, keys);
keys(TID) ->
    Server = libp2p_Swarm_sup:server(TID),
    gen_server:call(Server, keys).

%% @doc Get the peerbook for a swarm.
-spec peerbook(ets:tab() | pid()) -> pid().
peerbook(Sup) when is_pid(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, peerbook);
peerbook(TID) ->
    libp2p_swarm_sup:peerbook(TID).

%% @doc Get the options a swarm was started with.
-spec opts(ets:tab() | pid(), any()) -> swarm_opts() | any().
opts(Sup, Default) when is_pid(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, {opts, Default});
opts(TID, Default) ->
    libp2p_swarm_sup:opts(TID, Default).



% Transport
%

-spec add_transport_handler(supervisor:sup_ref(), atom())-> ok.
add_transport_handler(Sup, Transport) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {add_transport_handler, Transport}),
    ok.

% Listen
%

-spec listen(supervisor:sup_ref(), string() | non_neg_integer()) -> ok | {error, term()}.
listen(Sup, Port) when is_integer(Port)->
    listen(Sup, "/ip4/0.0.0.0/tcp/" ++ integer_to_list(Port));
listen(Sup, Addr) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, {listen, Addr}, infinity).

-spec listen_addrs(supervisor:sup_ref()) -> [string()].
listen_addrs(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, listen_addrs).


% Connect
%
-spec add_connection_handler(supervisor:sup_ref(), string(), {libp2p_transport:connection_handler(), libp2p_transport:connection_handler()}) -> ok.
add_connection_handler(Sup, Key, {ServerMF, ClientMF}) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {add_connection_handler, {Key, ServerMF, ClientMF}}),
    ok.

-spec connect(supervisor:sup_ref(), string()) -> {ok, libp2p_session:pid()} | {error, term()}.
connect(Sup, Addr) ->
    connect(Sup, Addr, [], ?CONNECT_TIMEOUT).

-spec connect(supervisor:sup_ref(), string(), [connect_opt()], pos_integer())
             -> {ok, libp2p_session:pid()} | {error, term()}.
connect(Sup, Addr, Options, Timeout) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, {connect_to, Addr, Options, Timeout}, infinity).


% Stream
%
-spec dial(supervisor:sup_ref(), string(), string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path) ->
    dial(Sup, Addr, Path, [], ?CONNECT_TIMEOUT).

-spec dial(supervisor:sup_ref(), string(), string(),[connect_opt()], pos_integer())
          -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path, Options, Timeout) ->
    % e.g. dial(SID, "/ip4/127.0.0.1/tcp/5555", "echo")
    case connect(Sup, Addr, Options, Timeout) of
        {error, Error} -> {error, Error};
        {ok, SessionPid} ->libp2p_session:start_client_stream(Path, SessionPid)
    end.

-spec add_stream_handler(supervisor:sup_ref(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Sup, Key, HandlerDef) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:cast(Server, {add_stream_handler, {Key, HandlerDef}}),
    ok.

-spec stream_handlers(supervisor:sup_ref()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    gen_server:call(Server, stream_handlers).
