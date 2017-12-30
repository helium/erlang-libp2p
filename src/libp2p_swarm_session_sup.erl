-module(libp2p_swarm_session_sup).

-behavior(supervisor).

% supervisor
-export([start_link/1, init/1]).
% api
-export([sup/1]).

-define(SUP, connection_sup).

start_link(TID) ->
    supervisor:start_link(?MODULE, [TID]).

init([TID]) ->
    _ = ets:insert(TID, {?SUP, self()}),
    SupFlags = #{ strategy  => one_for_one,
                  intensity => 0,
                  period    => 1 },
    {ok, {SupFlags, []}}.

-spec sup(ets:tab()) -> supervisor:sup_ref().
sup(TID) ->
    ets:lookup_element(TID, ?SUP, 2).

