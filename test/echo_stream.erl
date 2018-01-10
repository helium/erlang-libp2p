-module(echo_stream).

-behavior(libp2p_framed_stream).

-export([enter_loop/4, init/1, handle_data/2]).

-record(state, {}).

enter_loop(Connection, Path, _TID, _Args) ->
    libp2p_framed_stream:enter_loop(?MODULE, Connection, [Path]).

init([Path]) ->
    {ok, Path, #state{}}.

handle_data(Data, State=#state{}) ->
    {resp, Data, State}.
