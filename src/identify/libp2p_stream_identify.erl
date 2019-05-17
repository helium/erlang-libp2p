-module(libp2p_stream_identify).

-include("pb/libp2p_identify_pb.hrl").

-behavior(libp2p_stream).

%% API
-export([start/2, start/3]).
%% libp2p_stream
-export([init/2, handle_packet/4, handle_info/3]).

-record(state,
        { result_handler=undefinde :: pid() | undefined,
          muxer=undefined :: pid() | undefined
        }).

-define(PATH, "identify/1.0.0").
-define(DEFAULT_TIMEOUT, 5000).

-spec start(Muxer::pid(), ResultHandler::pid()) -> {ok, pid()} | {error, term()}.
start(Muxer, ResultHandler) ->
    start(Muxer, ResultHandler, ?DEFAULT_TIMEOUT).

-spec start(Muxer::pid(), ResultHandler::pid(), Timeout::pos_integer()) -> {ok, pid()} | {error, term()}.
start(Muxer, ResultHandler, Timeout) ->
    Challenge = base58:binary_to_base58(crypto:strong_rand_bytes(20)),
    Path = lists:flatten([?PATH, "/", Challenge]),
    ModOpts = #{ result_handler => ResultHandler,
                 identify_timeout => Timeout,
                 muxer => Muxer},
    libp2p_stream_muxer:dial(Muxer, #{ handlers => [{list_to_binary(Path), {?MODULE, ModOpts}}]
                                     }).

init(client, #{ result_handler := ResultHandler, muxer := Muxer, identify_timeout := IdentifyTimeout}) ->
    {ok, #state{result_handler=ResultHandler, muxer=Muxer},
     [{timer, identify_timeout, IdentifyTimeout},
      {packet_spec, [varint]},
      {active, once}]};
init(server, #{ path := Path, sig_fn := SigFun, peer := Peer }) ->
    <<$/, Str/binary>> = Path,
    Challenge = base58:base58_to_binary(binary_to_list(Str)),
    {_, RemoteAddr} = libp2p_stream_transport:stream_addr_info(),
    Identify = libp2p_identify:from_map(#{peer => Peer,
                                          observed_addr => RemoteAddr,
                                          nonce => Challenge}, SigFun),
    Data = libp2p_identify:encode(Identify),
    {stop, normal, undefined,
     [{send, libp2p_packet:encode_packet([varint], [byte_size(Data)], Data)}]}.


handle_packet(client, _, Data, State=#state{muxer=Muxer}) ->
    State#state.result_handler ! {handle_identify, Muxer, libp2p_identify:decode(Data)},
    {stop, normal, State,
    [{cancel_timer, identify_timeout}]}.


handle_info(client, {timeout, identify_timeout}, State=#state{}) ->
    State#state.result_handler ! {handle_identify, State#state.muxer, {error, timeout}},
    lager:notice("Identify timed out"),
    {stop, normal, State}.
