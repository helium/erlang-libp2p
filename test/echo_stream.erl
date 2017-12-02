-module(echo_stream).

-behavior(libp2p_framed_stream).

-export([start/4, init/1, handle_data/2]).

-record(state, {}).

start(Connection, Path, _TID, _Args) ->
    libp2p_framed_stream:start(?MODULE, Connection, [Path]).

init([Path]) ->
    {ok, Path, #state{}}.

handle_data(Data, State=#state{}) ->
    {resp, Data, State}.
