-module(libp2p_multistream_client).

-export([handshake/1, negotiate_handler/3, select/2, select_one/3, ls/1]).

-spec negotiate_handler([{string(), term()}], string(), libp2p_connection:connection())
                       -> {ok, term()} | server_switch | {error, term()}.
negotiate_handler(Handlers0, Path, Connection) ->
    %% filter out any handlers where the client side is undefined, eg. proxy
    Handlers = lists:filter(fun({_Name, {_ServerDef, undefined}}) -> false;
                                   (_) -> true
                            end, Handlers0),
    case ?MODULE:handshake(Connection) of
        {error, Error} ->
            lager:notice("Client handshake failed for ~p: ~p", [Path, Error]),
            libp2p_connection:close(Connection),
            {error, Error};
        server_switch ->
            lager:info("Simultaneous connection detected with ~p, elected to server role", [libp2p_connection:addr_info(Connection)]),
            server_switch;
        ok ->
            lager:debug("Negotiating handler for ~p using ~p", [Path, [Key || {Key, _} <- Handlers]]),
            case ?MODULE:select_one(Handlers, 1, Connection) of
                {error, Error} ->
                    lager:notice("Failed to negotiate handler for ~p: ~p", [Path, Error]),
                    {error, Error};
                {_, Handler} -> {ok, Handler}
            end
    end.

-spec select(string(), libp2p_connection:connection()) -> ok | {error, term()}.
select(Protocol, Connection) ->
    attempt_select(Protocol, Connection).

-spec select_one([tuple()], pos_integer(), libp2p_connection:connection()) -> tuple() | {error, term()}.
select_one([], _Index, _Connection) ->
    {error, protocol_unsupported};
select_one([Tuple | Rest], Index, Connection) when is_tuple(Tuple)->
    Key = element(Index, Tuple),
    case attempt_select(Key, Connection) of
        ok -> Tuple;
        {error, {protocol_unsupported, Key}} -> select_one(Rest, Index, Connection);
        {error, Reason} -> {error, Reason}
    end.

-spec ls(libp2p_connection:connection()) -> [string()] | {error, term()}.
ls(Connection) ->
    case libp2p_multistream:write(Connection, "ls") of
        ok -> libp2p_multistream:read_lines(Connection);
        {error, Error} -> {error, Error}
    end.

-spec handshake(libp2p_connection:connection()) -> ok | server_switch | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    case libp2p_multistream:read(Connection, rand:uniform(20000) + 15000) of
        Id ->
            ok = libp2p_multistream:write(Connection, Id);
        {error, timeout} ->
            ok = libp2p_multistream:write(Connection, Id),
            case libp2p_multistream:read(Connection) of
                Id ->
                    %% So this is a bit tricky, we managed to get a handshake by sending
                    %% first, which is usually what the server-side does. This means we've
                    %% likely made a 'simultaneous connection' such that both sides tried to dial
                    %% each other and they bypassed the listen socket. This happens because of
                    %% our port reuse trickery but we need to handle this case by promoting
                    %% one side to a server.
                    server_switch;
                Other -> Other
            end;
        {error, Reason} ->
            {error, Reason};
        ServerId -> {error, {protocol_mismatch, ServerId}}
    end.

-spec attempt_select(string(), libp2p_connection:connection()) -> ok | {error, term()}.
attempt_select(Protocol, Connection) ->
    case libp2p_multistream:write(Connection, Protocol) of
        ok -> case libp2p_multistream:read(Connection) of
                  Protocol -> ok;
                  "na" -> {error, {protocol_unsupported, Protocol}};
                  {error, Reason} -> {error, Reason}
              end;
        {error, Reason} -> {error, Reason}
    end.
