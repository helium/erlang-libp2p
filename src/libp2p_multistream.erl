-module(libp2p_multistream).

-record(multistream, {
          handlers={} :: handlers()
         }).

-type handlers() ::#{string() => atom()} | {}.
-type multistream() :: #multistream{}.

-export_type([multistream/0]).

-export([new/0, new/1, ls/1, handshake/1, select/2, select_one/2]).

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
    case write(Connection, "ls") of
        ok ->
            case read_varint(Connection) of
                {error, Reason} -> {error, Reason};
                Size -> read_lines(Connection, Size)
            end;
        {error, Error} -> {error, Error}
    end.

-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
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


read_lines(Connection, Size) ->
    case libp2p_connection:recv(Connection, Size) of
        {error, Reason} -> {error, Reason};
        <<Data:Size/binary>> ->
            {Count, Rest} = small_ints:decode_varint(Data),
            decode_lines(Rest, Count, [])
    end.

-spec decode_lines(binary(), non_neg_integer() | {error, term()}, list()) -> [string()] | {error, term()}.
decode_lines(_Bin, 0, Acc) ->
    lists:reverse(Acc);
decode_lines(Bin, Count, Acc) ->
    {Line, Rest} = decode_line(Bin),
    [Line | decode_lines(Rest, Count-1, Acc)].

-spec decode_line(binary()) -> {list(), binary()} | {error, term()}.
decode_line(Bin) ->
    {Size, Rest} = small_ints:decode_varint(Bin),
    decode_line_body(Rest, Size).

-spec decode_line_body(binary(), non_neg_integer()) -> {list(), binary()} | {error, term()}.
decode_line_body(Bin, Size) ->
    DataSize = Size -1,
    case Bin of
        <<Data:DataSize/binary, $\n, Rest/binary>> -> {binary_to_list(Data), Rest};
        <<Data:Size/binary>> -> {error, {missing_terminator, Data}}
    end.

-spec read_line(libp2p_connection:connection()) -> string() | {error, term()}.
read_line(Connection) ->
    case read_varint(Connection) of
        {error, Error} ->
            {error, Error};
        Size when Size > ?MAX_LINE_LENGTH ->
            {error, {line_too_long, Size}};
        Size ->
            case libp2p_connection:recv(Connection, Size) of
                {error, Error} -> {error, Error};
                <<Data:Size/binary>> ->
                    {Line, <<>>} = decode_line_body(Data, Size),
                    Line
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
