-module(libp2p_multistream_server).

-behavior(libp2p_connection_protocol).

-export([start_link/3, init/3,
         new/1, new/2, handle/1]).

-record(multistream_server, {
          connection :: libp2p_connection:connection(),
          handlers :: maps:map()
         }).

-type server() :: #multistream_server{}.

-spec new(libp2p_connection:connection()) -> server().
new(Connection) ->
    new(Connection, #{}).

-spec new(libp2p_connection:connection(), maps:map()) -> server().
new(Connection, Handlers) ->
    #multistream_server{connection=Connection, handlers=Handlers}.

%%
%% libp2p_connection_protocol
%%

start_link(Ref, Connection, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Connection, Opts]),
    {ok, Pid}.

init(Ref, Connection, _Opts) ->
    libp2p_connection:acknowledge(Connection, Ref),
    try
        handle(new(Connection))
    catch
        throw:{error, Reason} ->
            io:format("ERROR ~p~n", [Reason]),
            libp2p_connection:close(Connection)
    end.

%%
%% Command Serving
%%

handle(State=#multistream_server{connection=Conn, handlers=Handlers}) ->
    handshake(Conn),
    io:format("HANDSHAKE DONE~n"),
    case read(Conn) of
        "ls" ->
            handle_ls(Conn, Handlers);
        Line ->
            case maps:find(Line, Handlers) of
                {ok, {M, F, A}} -> M:F(Conn, A);
                error -> write(Conn, "na")
            end
    end,
    handle(State).

handle_ls(Conn, Handlers) ->
    case libp2p_multistream:write_lines(Conn, maps:keys(Handlers)) of
        ok -> ok;
        {error, Reason} -> throw({error, Reason})
    end.


-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    write(Connection, Id),
    case read(Connection) of
        Id -> ok;
        ClientId -> throw({error, {protocol_mismatch, ClientId}})
    end.

write(Conn, Data) ->
    case libp2p_multistream:write(Conn, Data) of
        ok -> ok;
        {error, Reason} -> throw({error, Reason})
    end.

read(Conn) ->
    case libp2p_multistream:read(Conn) of
        {error, Reason} -> throw({error, Reason});
        Data -> Data
    end.
