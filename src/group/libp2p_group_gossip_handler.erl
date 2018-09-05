-module(libp2p_group_gossip_handler).


-callback init_gossip_data(State::any()) -> init_result().
-callback handle_gossip_data(Msg::binary(), State::any()) -> handler_result().

-type init_result() :: ok | {send, binary()}.
-type handler_result() :: ok | {error, term()}.

-export_type([init_result/0, handler_result/0]).
