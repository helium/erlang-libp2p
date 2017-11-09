-module(libp2p_connection_protocol).

-callback start_link(reference(), libp2p_connection:connection()) -> {ok, pid()} | {ok, pid(), pid()}.
