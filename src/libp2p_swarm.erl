-module(libp2p_swarm).

-export([start/0, start/1, stop/1, swarm/1,
         dial/3, dial/5, connect/2, connect/4,
         listen/2, listen_addrs/1,
         add_transport_handler/2,
         add_connection_handler/3,
         add_stream_handler/3, stream_handlers/1]).

-type connect_opt() :: {unique_session, true | false}
                     | {unique_port, true | false}.

-define(CONNECT_TIMEOUT, 5000).


-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    case supervisor:start_link(libp2p_swarm_sup, []) of
        {ok, Pid} ->
            unlink(Pid),
            {ok, Pid};
        Other -> Other
    end.

-spec start(string() | non_neg_integer()) -> {ok, pid()} | ignore | {error, term()}.
start(Addr) ->
    case start() of
        {ok, Sup} ->
            case listen(Sup, Addr) of
                ok -> {ok, Sup};
                {error, Reason} -> {error, Reason}
            end;
        {error, Error} -> {error, Error}
    end.

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

% Transport
%

-spec add_transport_handler(supervisor:sup_ref(), atom())-> ok.
add_transport_handler(Sup, Transport) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:add_transport_handler(Server, Transport).

% Listen
%

-spec listen(supervisor:sup_ref(), string() | non_neg_integer()) -> ok | {error, term()}.
listen(Sup, Port) when is_integer(Port)->
    ListenAddr = "/ip4/0.0.0.0/tcp/" ++ integer_to_list(Port),
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
connect(Sup, Addr) ->
    connect(Sup, Addr, [], ?CONNECT_TIMEOUT).

-spec connect(supervisor:sup_ref(), string(), [connect_opt()], pos_integer())
             -> {ok, libp2p_session:pid()} | {error, term()}.
connect(Sup, Addr, Options, Timeout) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:connect(Server, Addr, Options, Timeout).


% Stream
%
-spec dial(supervisor:sup_ref(), string(), string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path) ->
    dial(Sup, Addr, Path, [], ?CONNECT_TIMEOUT).

-spec dial(supervisor:sup_ref(), string(), string(),[connect_opt()], pos_integer())
          -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Sup, Addr, Path, Options, Timeout) ->
    % e.g. dial(SID, "/ip4/127.0.0.1/tcp/5555", "echo")
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:dial(Server, Addr, Path, Options, Timeout).

-spec add_stream_handler(supervisor:sup_ref(), string(), libp2p_session:stream_handler()) -> ok.
add_stream_handler(Sup, Key, HandlerDef) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:add_stream_handler(Server, Key, HandlerDef).

-spec stream_handlers(supervisor:sup_ref()) -> [{string(), libp2p_session:stream_handler()}].
stream_handlers(Sup) ->
    Server = libp2p_swarm_sup:server(Sup),
    libp2p_swarm_server:stream_handlers(Server).
