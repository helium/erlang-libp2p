-module(serve_stream).

% public API
-export([register/2, dial/3,
         recv/2, recv/3, send/2, send/3,
         close/1, close_state/1]).

% internal API
-export([serve_stream/4]).

register(Swarm, Name) ->
    libp2p_swarm:add_stream_handler(Swarm, Name, {?MODULE, serve_stream, [self()]}).

serve_stream(Connection, _Path, _TID, [Parent]) ->
    Parent ! {hello, self()},
    serve_loop(Connection, Parent).

serve_loop(Connection, Parent) ->
    receive
        {send, Bin, Timeout} ->
            Result = libp2p_connection:send(Connection, Bin, Timeout),
            Parent ! {send, Result},
            serve_loop(Connection, Parent);
        {recv, N, Timeout} ->
            Result = libp2p_connection:recv(Connection, N, Timeout),
            Parent ! {recv, N, Result},
            serve_loop(Connection, Parent);
        close ->
            libp2p_connection:close(Connection),
            serve_loop(Connection, Parent);
        close_state ->
            Result = libp2p_connection:close_state(Connection),
            Parent ! {close_state, Result},
            serve_loop(Connection, Parent);
        stop ->
            libp2p_connection:close(Connection),
            ok
    end.

dial(FromSwarm, ToSwarm, Name) ->
    [ToAddr|_] = libp2p_swarm:listen_addrs(ToSwarm),
    {ok, Connection} = libp2p_swarm:dial(FromSwarm, ToAddr, Name),
    receive
        {hello, Server} -> Server
    end,
    {Connection, Server}.

send(Pid, Bin, Timeout) ->
    Pid ! {send, Bin, Timeout},
    Result = receive
                 {send, R} -> R
             end,
    Result.

send(Pid, Bin) ->
    send(Pid, Bin, 5000).

recv(Pid, Size) ->
    recv(Pid, Size, 1000).

recv(Pid, Size, Timeout) ->
    Pid ! {recv, Size, Timeout},
    Result = receive
                 {recv, Size, R} -> R
             end,
    Result.

close_state(Pid) ->
    Pid ! close_state,
    Result = receive
                 {close_state, R} -> R
             end,
    Result.

close(Pid) ->
    Pid ! close,
    ok.
