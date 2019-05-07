-module(libp2p_stream_muxer).

-callback open(StreamMuxer::pid()) -> Stream::pid().

-export([open/1,
         streams/2
        ]).

-spec open(pid()) -> {ok, pid()} | {error, term()}.
open(MuxerPid) ->
    libp2p_stream_transport:command(MuxerPid, stream_open).

-spec streams(pid(), libp2p_stream:kind()) -> {ok, [pid()]} | {error, term()}.
streams(MuxerPid, Kind) ->
    libp2p_stream_transport:command(MuxerPid, {stream_streams, Kind}).
