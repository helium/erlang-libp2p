-module(serve_stream).

% public API
-export([register/2, dial/3, recv/2, send/2, close/1]).

% internal API
-export([serve_stream/4]).

register(Swarm, Name) ->
    libp2p_swarm:add_stream_handler(Swarm, Name, {?MODULE, serve_stream, [self()]}).

serve_stream(Connection, _Path, _TID, [Parent]) ->
    Parent ! {hello, self()},
    serve_loop(Connection, Parent).

serve_loop(Connection, Parent) ->
    receive
        {send, Bin} ->
            Result = libp2p_connection:send(Connection, Bin),
            Parent ! {send, Result},
            serve_loop(Connection, Parent);
        {recv, N} ->
            Result = libp2p_connection:recv(Connection, N, 100),
            Parent ! {recv, N, Result},
            serve_loop(Connection, Parent);
        close ->
            libp2p_connection:close(Connection),
            serve_loop(Connection, Parent);
        stop ->
            libp2p_connecton:close(Connection),
            ok
    end.

dial(FromSwarm, ToSwarm, Name) ->
    [ToAddr] = libp2p_swarm:listen_addrs(ToSwarm),
    {ok, Stream} = libp2p_swarm:dial(FromSwarm, ToAddr, Name),
    receive
        {hello, Server} -> Server
    end,
    {Stream, Server}.

send(Pid, Bin) ->
    Pid ! {send, Bin},
    Result = receive
                 {send, R} -> R
             end,
    Result.

recv(Pid, Size) ->
    Pid ! {recv, Size},
    Result = receive
                 {recv, Size, R} -> R
             end,
    Result.

close(Pid) ->
    Pid ! close,
    ok.
