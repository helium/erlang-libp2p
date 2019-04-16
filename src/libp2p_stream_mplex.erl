-module(libp2p_stream_mplex).

-behavior(libp2p_stream).

-export([init/2]).

-record(state, {
                stream_id :: non_neg_integer()
               }).

-define(PACKET_SPEC, [varint, varint]).

init(_Kind, _Args) ->
    {ok, #state{}, [{packet_spec, ?PACKET_SPEC}]}.


handle_packet(_Kind, Header, Packet, State=state{}) ->
    {ok, State};
handle_packet() ->
