-module(libp2p_multistream_client).

-record(multistream_client, {
          connection :: libp2p_connection:connection(),
          did_handshake=false :: boolean()
         }).

-type client() :: #multistream_client{}.

-export([new/1, handshake/1, select/2, select_one/2, ls/1]).

-spec new(libp2p_connection:connection()) -> client().
new(Connection) ->
    #multistream_client{connection=Connection}.

-spec select(string(), libp2p_connection:connection()) -> ok | {error, term()}.
select(Protocol, Connection) ->
    attempt_select(Protocol, Connection).

-spec select_one([string()], libp2p_connection:connection()) -> string() | {error, term()}.
select_one([], _Connection) ->
    {error, protocol_unsupported};
select_one([Protocol | Rest], Connection) ->
    case attempt_select(Protocol, Connection) of
        ok -> Protocol;
        {error, {protocol_unsupported, Protocol}} -> select_one(Rest, Connection);
        {error, Reason} -> {error, Reason}
    end.

-spec ls(libp2p_connection:connection()) -> [string()] | {error, term()}.
ls(Connection) ->
    case libp2p_multistream:write(Connection, "ls") of
        ok -> libp2p_multistream:read_lines(Connection);
        {error, Error} -> {error, Error}
    end.

-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    case libp2p_multistream:read(Connection) of
        Id -> libp2p_multistream:write(Connection, Id);
        {error, Reason} -> {error, Reason};
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
