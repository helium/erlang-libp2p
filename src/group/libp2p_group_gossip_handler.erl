-module(libp2p_group_gossip_handler).


-callback init_gossip_data(State::any()) -> init_result().
-callback handle_gossip_data(StreamPid::pid(),
                             Msg::binary() | any(), % allow for the possibility of pre-decoded messages
                             State::any()) ->
    {reply, iodata()} | noreply.

-type init_result() :: ok | {send, binary()}.

-export_type([init_result/0]).
