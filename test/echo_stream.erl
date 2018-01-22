-module(echo_stream).

-behavior(libp2p_framed_stream).

-export([init/2, handle_data/3]).

-record(state, {}).

init(server, [Path]) ->
    {ok, Path, #state{}}.

handle_data(server, Data, State=#state{}) ->
    {resp, Data, State}.
