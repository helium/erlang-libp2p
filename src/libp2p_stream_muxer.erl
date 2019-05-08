-module(libp2p_stream_muxer).

-callback open(StreamMuxer::pid()) -> Stream::pid().

-export([dial/1,
         dial/2,
         streams/2
        ]).

-spec dial(pid()) -> {ok, pid()} | {error, term()}.
dial(MuxerPid) ->
    dial(MuxerPid, #{}).

dial(MuxerPid, Opts) ->
    libp2p_stream_transport:command(MuxerPid, {stream_dial, Opts}).


-spec streams(pid(), libp2p_stream:kind()) -> {ok, [pid()]} | {error, term()}.
streams(MuxerPid, Kind) ->
    libp2p_stream_transport:command(MuxerPid, {stream_streams, Kind}).
