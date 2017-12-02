-module(libp2p_multistream).

-export([protocol_id/0, read/1, read_lines/1, write/2, write_lines/2]).

-define(MAX_LINE_LENGTH, 64 * 1024).


protocol_id() ->
    "/multistream/1.0.0".

-spec write(libp2p_connection:connection(), binary() | string()) -> ok | {error, term()}.
write(Connection, Msg) when is_list(Msg) ->
    write(Connection, list_to_binary(Msg));
write(Connection, Msg) when is_binary(Msg) ->
    Data = <<(small_ints:encode_varint(byte_size(Msg) + 1))/binary, Msg/binary, $\n>>,
    libp2p_connection:send(Connection, Data).

write_lines(Connection, Lines) ->
    EncodedLines = encode_lines(Lines, <<>>),
    EncodedCount = small_ints:encode_varint(length(Lines)),
    Size = small_ints:encode_varint(byte_size(EncodedCount) + byte_size(EncodedLines)),
    libp2p_connection:send(Connection, <<Size/binary, EncodedCount/binary, EncodedLines/binary>>).

-spec read(libp2p_connection:connection()) -> string() | {error, term()}.
read(Connection) ->
    case read_varint(Connection) of
        {error, Error} ->
            {error, Error};
        {ok, Size} when Size > ?MAX_LINE_LENGTH ->
            {error, {line_too_long, Size}};
        {ok, Size} ->
            case libp2p_connection:recv(Connection, Size) of
                {error, Error} -> {error, Error};
                {ok, <<Data:Size/binary>>} ->
                    {Line, <<>>} = decode_line_body(Data, Size),
                    Line
            end
    end.

-spec read_lines(libp2p_connection:connection()) -> [string()] | {error, term()}.
read_lines(Connection) ->
    case read_varint(Connection) of
        {error, Reason} -> {error, Reason};
        {ok, Size} ->
            case libp2p_connection:recv(Connection, Size) of
                {error, Reason} -> {error, Reason};
                {ok, <<Data:Size/binary>>} ->
                    {Count, Rest} = small_ints:decode_varint(Data),
                    decode_lines(Rest, Count, [])
            end
    end.

encode_lines([], Acc) ->
    Acc;
encode_lines([Line | Tail], Acc) ->
    LineData = list_to_binary(Line),
    LineSize = small_ints:encode_varint(byte_size(LineData) + 1),
    <<LineSize/binary, LineData/binary, $\n, (encode_lines(Tail, Acc))>>.

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

-spec read_varint(libp2p_connection:connection()) -> {ok, non_neg_integer()} | {error, term()}.
read_varint(Connection) ->
    read_varint(Connection, 0, 0).

read_varint(Connection, Position, Acc) ->
    case libp2p_connection:recv(Connection, 1) of
        {ok, <<1:1, Number:7>>} ->
            read_varint(Connection, Position + 7, (Number bsl Position) + Acc);
        {ok, <<0:1, Number:7>>} ->
            {ok, (Number bsl Position) + Acc};
        {error, Error} -> {error, Error}
    end.
