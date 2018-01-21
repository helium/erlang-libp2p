-module(echo_stream).

-behavior(libp2p_framed_stream).

-export([init/1, handle_data/2]).

-record(state, {}).

init([Path]) ->
    {ok, Path, #state{}}.

handle_data(Data, State=#state{}) ->
    {resp, Data, State}.
