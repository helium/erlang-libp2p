-module(libp2p_stream_muxer).

-callback open(StreamMuxer::pid()) -> Stream::pid().

-export([open/1]).

-spec open(pid()) -> {ok, pid()} | {error, term()}.
open(MuxerPid) ->
    libp2p_stream_transport:command(MuxerPid, open).
