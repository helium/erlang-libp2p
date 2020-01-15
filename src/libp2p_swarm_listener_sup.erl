-module(libp2p_swarm_listener_sup).

-behavior(supervisor).

% supervisor
-export([init/1, start_link/1]).
% api
-export([sup/1]).

-define(SUP, listener_sup).

start_link(TID) ->
    supervisor:start_link(reg_name(TID), ?MODULE, [TID]).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

init([TID]) ->
    _ = ets:insert(TID, {?SUP, self()}),
    SupFlags = #{strategy  => one_for_one},
    {ok, {SupFlags, []}}.

-spec sup(ets:tab()) -> pid().
sup(TID) ->
    ets:lookup_element(TID, ?SUP, 2).


