-module(libp2p_group_relcast_handler).


-callback init(Args::any()) ->
    {ok, TargetAddrs::[libp2p_crypto:address()], State::any()}
        | {error, term()}.
-callback handle_input(Msg::binary(), State::any()) -> handler_result().
-callback handle_message(Index::pos_integer(), Msg::binary(), State::any()) -> handler_result().

-type handler_result() ::
        {State::any(), ok} |
        {State, {send, [message()]}} |
        {State, stop, Reason::any()}.

-type message() ::
        {unicast, Index::pos_integer(), Msg::binary()} |
        {multicast, Msg::binary()}.
