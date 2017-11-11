-module(libp2p_multistream).

-record(multistream, {
          handlers={} :: handlers()
         }).

-type handlers() ::#{string() => atom()} | {}.
-type multistream() :: #multistream{}.

-export_type([multistream/0]).

-export([new/0, new/1, ls/1, select/2, select_one/2]).

-define(PROTOCOL_ID, "/multistream/1.0.0").
-define(MAX_LINE_LENGTH, 64 * 1024).

-spec new() -> multistream().
new() ->
    #multistream{}.

-spec new(handlers()) -> multistream().
new(Handlers) ->
    #multistream{handlers=Handlers}.

%%
%% Client API
%%

-spec select(string(), libp2p_connection:connection()) -> ok | {error, term()}.
select(Protocol, Connection) ->
    case handshake_client(Connection) of
        ok -> attempt_select(Protocol, Connection);
        {error, Reason} -> {error, Reason}
    end.

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
    case write(Connection, "ls") of
        ok -> read_lines(Connection, read_varint(Connection), []);
        {error, Error} -> {error, Error}
    end.

-spec handshake_client(libp2p_connection:connection()) -> ok | {error, term()}.
handshake_client(Connection) ->
    case read_line(Connection) of
        ?PROTOCOL_ID -> write(Connection, ?PROTOCOL_ID);
        {error, Reason} -> {error, Reason};
        Data -> {error, {protocol_mismatch, Data}}
    end.

-spec attempt_select(string(), libp2p_connection:connection()) -> ok | {error, term()}.
attempt_select(Protocol, Connection) ->
    case write(Connection, Protocol) of
        ok -> case read_line(Connection) of
                  Protocol -> ok;
                  "na" -> {error, {protocol_unsupported, Protocol}};
                  {error, Reason} -> {error, Reason}
              end;
        {error, Reason} -> {error, Reason}
    end.

%%
%% Utilities
%%

-spec write(libp2p_connection:connection(), binary() | string()) -> ok | {error, term()}.
write(Connection, Msg) when is_list(Msg) ->
    write(Connection, list_to_binary(Msg));
write(Connection, Msg) when is_binary(Msg) ->
    Data = <<(small_ints:encode_varint(byte_size(Msg) + 1))/binary, Msg/binary, $\n>>,
    libp2p_connection:send(Connection, Data).

-spec read_lines(libp2p_connection:connection(), non_neg_integer() | {error, term()}, list()) -> [string()] | {error, term()}.
read_lines(_Connection, Error={error, _}, _Acc) ->
    Error;
read_lines(_Connection, 0, Acc) ->
    lists:reverse(Acc);
read_lines(Connection, Count, Acc) ->
    [read_line(Connection) | read_lines(Connection, Count-1, Acc)].

-spec read_line(libp2p_connection:connection()) -> string() | {error, term()}.
read_line(Connection) ->
    case read_varint(Connection) of
        {error, Error} ->
            {error, Error};
        Size when Size > ?MAX_LINE_LENGTH ->
            {error, {line_too_long, Size}};
        Size ->
            DataSize = Size -1,
            case libp2p_connection:recv(Connection, Size) of
                <<Data:DataSize/binary, $\n>> -> binary_to_list(Data);
                <<Data:Size/binary>> -> {error, {missing_terminator, Data}};
                {error, Error} -> {error, Error}
            end
    end.


-spec read_varint(libp2p_connection:connection()) -> non_neg_integer() | {error, term()}.
read_varint(Connection) ->
    read_varint(Connection, 0, 0).

read_varint(Connection, Position, Acc) ->
    case libp2p_connection:recv(Connection, 1) of
        <<1:1, Number:7>> ->
            read_varint(Connection, Position + 7, (Number bsl Position) + Acc);
        <<0:1, Number:7>> ->
            (Number bsl Position) + Acc;
        {error, Error} -> {error, Error}
    end.
