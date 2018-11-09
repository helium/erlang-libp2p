-module(relcast_handler).

-behavior(relcast).

-export([init/1, handle_message/3, handle_command/2, callback_message/3, serialize/1, deserialize/1, restore/2]).

-record(state,
        { message_handler,
          input_handler,
          skip_handler=false
       }).

init([_Members, InputHandler, MessageHandler]) ->
    {ok, #state{message_handler=MessageHandler, input_handler=InputHandler}}.

handle_message(_Msg, _Index, State=#state{message_handler=undefined}) ->
    ct:pal("handle_message no handler", []),
    {State, []};
handle_message(_Msg, _Index, State = #state{skip_handler=true}) ->
    ct:pal("skipping message ~p", [_Msg]),
    {State#state{skip_handler=false}, []};
handle_message(Msg, Index, State=#state{message_handler=Handler}) ->
    ct:pal("handle_message with handler ~p(~p, ~p) -> ~p", [Handler, Index, Msg, Handler(Index, Msg)]),
    case Handler(Index, Msg) of
        defer -> defer;
        ignore -> ignore;
        Res ->
            {State, Res}
    end.

handle_command(_Msg, #state{input_handler=undefined}) ->
    ct:pal("handle_command no handler", []),
    {reply, ok, ignore};
handle_command(undefer, State) ->
    {reply, ok, [], State#state{skip_handler=true}};
handle_command(Msg, State=#state{input_handler=Handler}) ->
    ct:pal("handle_command with handler ~p(~p) -> ~p", [Handler, Msg, Handler(Msg)]),
    {reply, ok, Handler(Msg), State}.

callback_message(_, _, _) ->
    none.

serialize(State) ->
    term_to_binary(State).

deserialize(State) ->
    binary_to_term(State).

restore(OldState, _NewState) ->
    OldState.
