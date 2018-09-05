-module(libp2p_group_gossip_sup).

-behavior(supervisor).

%% API
-export([start_link/1, workers/1]).
%% supervisor
-export([init/1]).

-define(WORKERS, workers).

start_link(TID) ->
    supervisor:start_link(?MODULE, [TID]).

init([TID]) ->
    SupFlags = #{strategy => one_for_all},
    ChildSpecs =
        [
         #{ id => ?WORKERS,
            start => {libp2p_group_worker_sup, start_link, []},
            type => supervisor
          },
         #{ id => server,
            start => {libp2p_group_gossip_server, start_link, [self(), TID]},
            restart => transient
          }
        ],
    {ok, {SupFlags, ChildSpecs}}.


workers(Sup) ->
    Children = supervisor:which_children(Sup),
    {?WORKERS, Pid, _, _} = lists:keyfind(?WORKERS, 1, Children),
    Pid.
