-module(libp2p_swarm).

-export([start/1, stop/1, dial/3, connect/2, listen/2, listen_addrs/1,
         add_connection_handler/3, add_stream_handler/3, stream_handlers/1]).

-spec start(string() | non_neg_integer()) -> supervisor:sup_ref().
start(Addr) ->
    {ok, Sup} = supervisor:start_link(libp2p_swarm_sup, []),
    ok = listen(Sup, Addr),
    Sup.


-spec stop(supervisor:sup_ref()) -> ok.
stop(Sup) ->
    Ref = erlang:monitor(process, Sup),
    exit(Sup, normal),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 1000 ->
            error(timeout)
    end.

% Listen
%

-spec listen(supervisor:sup_ref(), string() | non_neg_integer()) -> ok | {error, term()}.
listen(Sup, Port) when is_integer(Port)->
    ListenAddr = "/ip4/127.0.0.1/tcp/" ++ integer_to_list(Port),
    listen(Sup, ListenAddr);
listen(Sup, Addr) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:listen(Server, Addr).

-spec listen_addrs(supervisor:sup_ref()) -> [string()].
listen_addrs(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:listen_addrs(Server).

% Connect
%
-spec add_connection_handler(supervisor:sup_ref(), string(), {libp2p_transport:connection_handler(), libp2p_transport:connection_handler()}) -> ok.
add_connection_handler(Sup, Key, HandlerDef) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:add_connection_handler(Server, Key, HandlerDef).

-spec connect(supervisor:sup_ref(), string()) -> {ok, libp2p_session:pid()} | {error, term()}.
connect(Sup, Port) when is_integer(Port) ->
    ConnAddr = "/ip4/127.0.0.1/tcp/" ++ integer_to_list(Port),
    connect(Sup, ConnAddr);
connect(Sup, Addr) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:connect(Server, Addr).

% Stream
%
-spec dial(supervisor:sup_ref(), string(), string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path) ->
    % e.g. dial(SID, "/ip4/127.0.0.1/tcp/5555", "echo")
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:dial(Server, Addr, Path).

-spec add_stream_handler(supervisor:sup_ref(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Sup, Key, HandlerDef) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:add_stream_handler(Server, Key, HandlerDef).

-spec stream_handlers(supervisor:sup_ref()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:stream_handlers(Server).
