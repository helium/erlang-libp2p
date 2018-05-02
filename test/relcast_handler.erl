-module(relcast_handler).

-behavior(libp2p_group_relcast_handler).

-export([init/1, handle_message/3, handle_input/2]).

-record(state,
        { message_handler,
          input_handler
       }).

init([Members, InputHandler, MessageHandler]) ->
    {ok, Members, #state{message_handler=MessageHandler, input_handler=InputHandler}}.

handle_message(Index, Msg, State=#state{message_handler=Handler}) ->
    {State, Handler(Index, Msg)}.

handle_input(Msg, State=#state{input_handler=Handler}) ->
    {State, Handler(Msg)}.
