-module(libp2p_swarm_listener_sup).

-behavior(supervisor).

-type ref() :: supervisor:sup_ref().

-export_type([ref/0]).

% supervisor
-export([init/1, start_link/1]).
% api
-export([sup/1]).

-define(SUP, listener_sup).

start_link(TID) ->
    supervisor:start_link(?MODULE, [TID]).

init([TID]) ->
    _ = ets:insert(TID, {?SUP, self()}),
    SupFlags = #{strategy  => one_for_one,
                 intensity => 0,
                 period    => 1},
    {ok, {SupFlags, []}}.

-spec sup(ets:tab()) -> ref().
sup(TID) ->
    ets:lookup_element(TID, ?SUP, 2).
