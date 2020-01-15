-module(libp2p_group_worker_sup).

-behavior(supervisor).

-export([start_link/1, init/1]).

start_link(TID) ->
    supervisor:start_link(reg_name(TID), ?MODULE, [TID]).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

init([_TID]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 100
                },
    {ok, {SupFlags, []}}.
