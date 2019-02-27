-module(libp2p_secio).

-export([
    read/1, read/2,
    read_lines/1,
    write/2,
    write_lines/2
]).

-define(MAX_LINE_LENGTH, 64 * 1024).
-define(RECV_TIME, 60000).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec read(libp2p_connection:connection()) -> binary() | {error, term()}.
read(Connection) ->
    read(Connection, ?RECV_TIME).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec read(libp2p_connection:connection(), pos_integer()) -> binary() | {error, term()}.
read(Connection, Timeout) ->
    case read_varint(Connection, Timeout) of
        {error, Error} ->
            {error, Error};
        {ok, Size} when Size > ?MAX_LINE_LENGTH ->
            {error, {line_too_long, Size}};
        {ok, Size} ->
            case libp2p_connection:recv(Connection, Size, Timeout) of
                {error, Error} -> {error, Error};
                {ok, <<Data:Size/binary>>} ->
                    {Line, <<>>} = decode_line_body(Data, Size),
                    Line
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec read_lines(libp2p_connection:connection()) -> [binary()] | {error, term()}.
read_lines(Connection) ->
    case read_varint(Connection, ?RECV_TIME) of
        {error, Reason} -> {error, Reason};
        {ok, Size} ->
            case libp2p_connection:recv(Connection, Size) of
                {error, Reason} -> {error, Reason};
                {ok, <<Data:Size/binary>>} ->
                    {Count, Rest} = small_ints:decode_varint(Data),
                    try
                        decode_lines(Rest, Count, [])
                    catch
                        throw:{error, R} -> {error, R}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec write(libp2p_connection:connection(), binary()) -> ok | {error, term()}.
write(Connection, Msg) when is_binary(Msg) ->
    Data = <<(small_ints:encode_varint(byte_size(Msg) + 1))/binary, Msg/binary, $\n>>,
    libp2p_connection:send(Connection, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec write_lines(libp2p_connection:connection(), [binary()]) -> ok | {error, term()}.
write_lines(Connection, Lines) ->
    EncodedLines = encode_lines(Lines, <<>>),
    EncodedCount = small_ints:encode_varint(length(Lines)),
    Size = small_ints:encode_varint(byte_size(EncodedCount) + byte_size(EncodedLines)),
    libp2p_connection:send(Connection, <<Size/binary, EncodedCount/binary, EncodedLines/binary>>).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec encode_lines([binary()], binary()) -> binary().
encode_lines([], Acc) ->
    Acc;
encode_lines([Line | Tail], Acc) ->
    LineSize = small_ints:encode_varint(byte_size(Line) + 1),
    <<LineSize/binary, Line/binary, $\n, (encode_lines(Tail, Acc))/binary>>.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec decode_lines(binary(), non_neg_integer() | {error, term()}, list()) -> [binary()].
decode_lines(_Bin, 0, Acc) ->
    lists:reverse(Acc);
decode_lines(Bin, Count, Acc) ->
    case decode_line(Bin) of
        {error, Error} -> throw({error, Error});
        {Line, Rest} -> [Line | decode_lines(Rest, Count-1, Acc)]
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec decode_line(binary()) -> {binary(), binary()} | {error, term()}.
decode_line(Bin) ->
    {Size, Rest} = small_ints:decode_varint(Bin),
    decode_line_body(Rest, Size).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec decode_line_body(binary(), non_neg_integer()) -> {binary(), binary()} | {error, term()}.
decode_line_body(Bin, Size) ->
    DataSize = Size -1,
    case Bin of
        <<Data:DataSize/binary, $\n, Rest/binary>> -> {Data, Rest};
        <<Data:Size/binary>> -> {error, {missing_terminator, Data}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec read_varint(libp2p_connection:connection(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
read_varint(Connection, Timeout) ->
    read_varint(Connection, Timeout, 0, 0).

read_varint(Connection, Timeout, Position, Acc) ->
    case libp2p_connection:recv(Connection, 1) of
        {ok, <<1:1, Number:7>>} ->
            read_varint(Connection, Timeout, Position + 7, (Number bsl Position) + Acc);
        {ok, <<0:1, Number:7>>} ->
            {ok, (Number bsl Position) + Acc};
        {error, Error} -> {error, Error}
    end.
