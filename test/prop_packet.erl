-module(prop_packet).

-include_lib("proper/include/proper.hrl").

-export([prop_decode_header/0]).

prop_decode_header() ->
    ?FORALL({Spec, Data}, random_packet(),
            begin
                MinSize = libp2p_packet:header_spec_size(Spec),
                case libp2p_packet:decode_header(Spec, Data) of
                    {more, M} ->
                        %% varints make it much harder to predict what
                        %% the 'M' should be since they add a random
                        %% number of prefix bytes. This means that
                        %% MinSize + M could actually be < byte_size
                        %% data.
                        M >= 1;
                    {ok, Header, PacketSize, Tail} ->
                        byte_size(Header) >= MinSize andalso
                            PacketSize >= 0 andalso
                            byte_size(Tail) >= 0;
                    _ ->
                        false
                end
            end).

prop_encode_decode_header() ->
    ?FORALL({Spec, Header, Data}, good_packet(),
           begin
               case libp2p_packet:decode_header(Spec, <<Header/binary, Data/binary>>) of
                   {ok, DecodedHeader, PacketSize, Tail} ->
                       DecodedHeader =:= Header andalso
                           PacketSize =:= byte_size(Data) andalso
                           Data =:= Tail;
                   {more, _} ->
                       false
               end
           end).

%%
%% Generators
%%

random_packet() ->
    {header_spec(), binary()}.

good_packet() ->
    ?LET(Spec, header_spec(), gen_spec_packet(Spec)).

header_spec() ->
    list(oneof([u8,u16,u16le,u32,u32le,varint])).

gen_spec_binary_rest(u8) ->
    crypto:strong_rand_bytes(rand:uniform(10));
gen_spec_binary_rest(_) ->
    crypto:strong_rand_bytes(rand:uniform(5)).

gen_spec_packet([]) ->
    {[], <<>>, <<>>};
gen_spec_packet(Spec) ->
    {SpecHead, [SpecLast]} = lists:split(length(Spec) - 1, Spec),
    ValueHead = [gen_spec_value(T) || T <- SpecHead],
    Data = gen_spec_binary_rest(SpecLast),
    ValueLast = gen_spec_binary(SpecLast, byte_size(Data)),
    HeaderBins = [gen_spec_binary(S, V) || {S, V} <- lists:zip(SpecHead, ValueHead)] ++ [ValueLast],
    Header = lists:foldr(fun(B, Acc) ->
                                 <<B/binary, Acc/binary>>
                         end, <<>>, HeaderBins),
    {Spec, Header, Data}.

gen_spec_value(u8) ->
    rand:uniform(256) - 1;
gen_spec_value(u16) ->
    rand:uniform(65536) - 1;
gen_spec_value(u16le) ->
    rand:uniform(65536) - 1;
gen_spec_value(u32) ->
    rand:uniform(4294967296) - 1;
gen_spec_value(u32le) ->
    rand:uniform(4294967296) - 1;
gen_spec_value(varint) ->
    gen_spec_value(u32).


gen_spec_binary(u8, Val) ->
    <<Val:8/integer-unsigned>>;
gen_spec_binary(u16, Val) ->
    <<Val:16/integer-unsigned-big>>;
gen_spec_binary(u16le, Val) ->
    <<Val:16/integer-unsigned-little>>;
gen_spec_binary(u32, Val) ->
    <<Val:32/integer-unsigned-big>>;
gen_spec_binary(u32le, Val) ->
    <<Val:32/integer-unsigned-little>>;
gen_spec_binary(varint ,Val) ->
    <<(encode_varint(Val))/binary>>.

encode_varint(I) when is_integer(I), I >= 0, I =< 127 ->
    <<I>>;
encode_varint(I) when is_integer(I), I > 127 ->
    <<1:1, (I band 127):7, (encode_varint(I bsr 7))/binary>>;
encode_varint(I) when is_integer(I), I < 0 ->
    erlang:error({badarg, I}).
