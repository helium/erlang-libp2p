-module(libp2p_connection_policy).


-export([init/1]).


-callback init(ets:tab()) -> {ok, any()} | {error, term()}.


-record(state,
       { tid :: ets:tab(),
         max_connections :: integer()
       }).

-define(DEFAULT_MAX_CONNECTIONS, 5).

-spec init(ets:tab()) -> {ok, any()} | {error, term()}.
init(TID) ->
    Opts = libp2p_swarm:opts(TID, []),
    MaxConnections = libp2p_config:get_opt(Opts, [?MODULE, max_connections],
                                          ?DEFAULT_MAX_CONNECTIONS),
    {ok, #state{tid=TID, max_connections=MaxConnections}}.
