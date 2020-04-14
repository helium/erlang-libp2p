-module(libp2p_peer_gossip_handler).
-callback init_gossip_data(State::any()) -> init_result().
-callback handle_gossip_data(StreamPid::pid(), MsgOrData::[libp2p_crypto:pubkey_bin()] | binary(), State::any()) -> {reply, iodata()} | noreply.

-type init_result() :: ok | {send, binary()}.

-export_type([init_result/0]).
