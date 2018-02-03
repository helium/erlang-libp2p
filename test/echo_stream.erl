-module(echo_stream).

-behavior(libp2p_framed_stream).

-export([init/3, handle_data/3]).

-record(state, {}).

init(server, _Connection, [Path]) ->
    {ok, Path, #state{}}.

handle_data(server, Data, State=#state{}) ->
    {resp, Data, State}.
