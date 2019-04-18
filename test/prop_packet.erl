-module(prop_packet).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

prop_decode_header() ->
    ?FORALL({Spec, Data}, random_packet(),
            begin
                case libp2p_packet:decode_header(Spec, Data) of
                    {more, M} ->
                        %% varints make it much harder to predict what
                        %% the 'M' should be since they add a random
                        %% number of prefix bytes. This means that
                        %% spec_size(Spec) + M could actually be < byte_size
                        %% data.
                        M >= 1 andalso
                            %% if a header is too short, then decoding
                            %% a full packet should respond the same
                            %% way
                            {more, M} =:= libp2p_packet:decode_packet(Spec, Data);
                    {ok, Header, Tail} ->
                        case lists:last(Header) of
                            PacketSize when PacketSize > byte_size(Tail) ->
                                Missing = PacketSize - byte_size(Tail),
                                {more, Missing} =:= libp2p_packet:decode_packet(Spec, Data) andalso
                                    length(Header) == length(Spec);
                            PacketSize ->
                                length(Header) == length(Spec) andalso
                                    PacketSize >= 0 andalso
                                    byte_size(Tail) >= 0
                        end
                end
            end).

prop_encode_decode_header() ->
    ?FORALL({Spec, Header}, header(),
           begin
               HeaderBin = libp2p_packet:encode_header(Spec, Header),
               {ok, Header, <<>>} == libp2p_packet:decode_header(Spec, HeaderBin)
           end).

prop_encode_decode_packet() ->
    ?FORALL({Spec, Header, Data}, packet(),
            begin
                MaxDataSize = max_value(lists:last(Spec)),
                case MaxDataSize =< byte_size(Data) of
                    true ->
                        case (catch libp2p_packet:encode_packet(Spec, Header, Data)) of
                            {'EXIT', {{cannot_encode, _}, _}} -> true;
                            _ ->
                                false
                        end;
                    false ->
                        EncodedPacket = libp2p_packet:encode_packet(Spec, Header, Data),
                        case libp2p_packet:decode_packet(Spec, EncodedPacket) of
                            {ok, DecHeader, DecData, Tail} ->
                                %% Match header
                                DecHeader =:= Header andalso
                                %% and data
                                    DecData =:= Data andalso
                                %% No remaining data
                                    byte_size(Tail) =:= 0
                        end
                end
            end).

%%
%% Generators
%%

random_packet() ->
    {spec(), binary()}.

spec() ->
    non_empty(list(oneof([u8,u16,u16le,u32,u32le,varint]))).

header() ->
    ?LET(Pairs, non_empty(list(oneof(
                                 [{u8, integer(0, max_value(u8))},
                                  {u16, integer(0, max_value(u16))},
                                  {u16le, integer(0, max_value(u16le))},
                                  {u32, integer(0, max_value(u32))},
                                  {u32le, integer(0, max_value(u32le))},
                                  {varint, integer(0, max_value(varint))}
                                 ]))),
         lists:unzip(Pairs)).

packet() ->
    ?LET(Header, header(),
         ?LET(Data, ?SIZED(Size, binary(10*Size)),
              begin
                  {Spec, HeaderVals} = Header,
                  {Spec, lists:droplast(HeaderVals) ++ [byte_size(Data)], Data}
              end)).


max_value(u8) ->
    255;
max_value(u16) ->
    65535;
max_value(u16le) ->
    65535;
max_value(u32) ->
    4294967295;
max_value(u32le) ->
    4294967295;
max_value(varint) ->
    4294967295.

%%
%% EUnit
%%

bad_varint_test() ->
    ?assertError({badarg, _}, libp2p_packet:encode_varint(-1)),
    ok.

bad_header_length_test() ->
    ?assertError(header_length, libp2p_packet:encode_header([u8], [])).
