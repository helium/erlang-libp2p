-module(libp2p_packet).

-type spec_type() :: u8 | u16 |  u16le | u32 |  u32le | varint.
-type spec() :: [spec_type()].
-type header() :: [non_neg_integer()].

-export_type([spec/0, spec_type/0, header/0]).

-export([spec_size/1,
         encode_header/2, decode_header/2,
         encode_packet/3, decode_packet/2,
         encode_varint/1, decode_varint/1]).

-spec encode_header(spec(), header()) -> binary().
encode_header(Spec, Header) when length(Spec) == length(Header) andalso length(Spec) > 0 ->
    encode_header(Spec, Header, <<>>);
encode_header(_, _) ->
    erlang:error(header_length).

-spec decode_header(spec(), binary()) ->
                           {ok, Header::header(), Tail::binary()} | {more, Expected::pos_integer()}.
decode_header(Spec, Bin) ->
    decode_header(Spec, Bin, []).


-spec encode_packet(spec(), header(), Data::binary()) -> binary().
encode_packet(Spec, Header, Data) ->
    BinHeader = encode_header(Spec, Header),
    <<BinHeader/binary, Data/binary>>.


-spec decode_packet(spec(), binary()) -> {ok, Header::header(), Data::binary(), Tail::binary()}
                                                    | {more, Expected::pos_integer()}.
decode_packet(Spec, Bin) ->
    case decode_header(Spec, Bin) of
        {ok, Header, Tail}  ->
            case lists:last(Header) of
                PacketSize when PacketSize =< byte_size(Tail) ->
                    <<Packet:PacketSize/binary, Rest/binary>> = Tail,
                    {ok, Header, Packet, Rest};
                PacketSize ->
                    {more, PacketSize - byte_size(Tail)}
            end;
        {more, N} ->
            {more, N}
    end.


-spec encode_header(spec(), header(), Acc::binary()) -> binary().
encode_header([], [], Acc) ->
    Acc;
encode_header([u8 | SpecTail], [V | HeaderTail], Acc ) when V >= 0, V < 256->
    encode_header(SpecTail, HeaderTail, <<Acc/binary, V:8/unsigned-integer>>);
encode_header([u16 | SpecTail], [V | HeaderTail], Acc ) when V >= 0, V < 65536->
    encode_header(SpecTail, HeaderTail, <<Acc/binary, V:16/unsigned-integer-big>>);
encode_header([u16le | SpecTail], [V | HeaderTail], Acc ) when V >= 0, V < 65536 ->
    encode_header(SpecTail, HeaderTail, <<Acc/binary, V:16/unsigned-integer-little>>);
encode_header([u32 | SpecTail], [V | HeaderTail], Acc ) when V >= 0, V < 4294967296 ->
    encode_header(SpecTail, HeaderTail, <<Acc/binary, V:32/unsigned-integer-big>>);
encode_header([u32le | SpecTail], [V | HeaderTail], Acc ) when V >= 0, V < 4294967296 ->
    encode_header(SpecTail, HeaderTail, <<Acc/binary, V:32/unsigned-integer-little>>);
encode_header([varint | SpecTail], [V | HeaderTail], Acc ) when V >= 0, V < 4294967296 ->
    VBin = encode_varint(V),
    encode_header(SpecTail, HeaderTail, <<Acc/binary, VBin/binary>>);
encode_header([Type | _], [V | _], _) ->
    erlang:error({cannot_encode, {Type, V}}).


-spec decode_header(spec(), binary(), Header::header()) ->
                           {ok, Header::header(), Tail::binary()} | {more, Expected::pos_integer()}.
decode_header([], Bin, Header) ->
    {ok, lists:reverse(Header), Bin};
decode_header([u8 | Tail], <<V:8/unsigned-integer, Rest/binary>>, Header) ->
    decode_header(Tail, Rest, [V | Header]);
decode_header([u16 | Tail], <<V:16/unsigned-integer-big, Rest/binary>>, Header) ->
    decode_header(Tail, Rest, [V | Header]);
decode_header([u16le | Tail], <<V:16/unsigned-integer-little, Rest/binary>>, Header) ->
    decode_header(Tail, Rest, [V | Header]);
decode_header([u32 | Tail], <<V:32/unsigned-integer-big, Rest/binary>>, Header) ->
    decode_header(Tail, Rest, [V | Header]);
decode_header([u32le | Tail], <<V:32/unsigned-integer-little, Rest/binary>>, Header) ->
    decode_header(Tail, Rest, [V | Header]);
decode_header(Spec=[varint | Tail], Bin, Header) ->
    case decode_varint(Bin) of
        {more, Used} -> {more, Used + spec_size(Spec)};
        {V, Rest} -> decode_header(Tail, Rest, [V | Header])
    end;
decode_header(Spec, Bin, _) ->
    SpecSize = spec_size(Spec, 0),
    {more, SpecSize - byte_size(Bin)}.


-spec spec_size(spec()) -> MinSize::non_neg_integer().
spec_size(Spec) ->
    spec_size(Spec, 0).

-spec spec_size(spec(), Acc::non_neg_integer()) -> MinSize::non_neg_integer().
spec_size([], Acc) ->
    Acc;
spec_size([u8 | Tail], Acc) ->
    spec_size(Tail, Acc + 1);
spec_size([u16 | Tail], Acc) ->
    spec_size(Tail, Acc + 2);
spec_size([u16le | Tail], Acc) ->
    spec_size(Tail, Acc + 2);
spec_size([u32 | Tail], Acc) ->
    spec_size(Tail, Acc + 4);
spec_size([u32le | Tail], Acc) ->
    spec_size(Tail, Acc + 4);
spec_size([varint | Tail], Acc) ->
    spec_size(Tail, Acc + 1).


-spec decode_varint(binary()) -> {non_neg_integer(), Rest::binary()} | {more, Used::non_neg_integer()}.
decode_varint(Bin) ->
    decode_varint(Bin, 0, 0).

-spec decode_varint(binary(), non_neg_integer(), non_neg_integer())
                   -> {non_neg_integer(), Rest::binary()} | {more, Used::non_neg_integer()}.
decode_varint(<<1:1, Number:7, Rest/binary>>, Position, Acc) ->
    decode_varint(Rest, Position + 7, (Number bsl Position) + Acc);
decode_varint(<<0:1, Number:7, Rest/binary>>, Position, Acc) ->
    {(Number bsl Position) + Acc, Rest};
decode_varint(<<>>, Position, _) ->
    {more, Position div 7}.


-spec encode_varint(non_neg_integer()) -> binary().
encode_varint(I) when is_integer(I), I >= 0, I =< 127 ->
    <<I>>;
encode_varint(I) when is_integer(I), I > 127 ->
    <<1:1, (I band 127):7, (encode_varint(I bsr 7))/binary>>;
encode_varint(I) when is_integer(I), I < 0 ->
    erlang:error({badarg, I}).
