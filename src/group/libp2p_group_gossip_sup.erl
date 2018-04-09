-module(libp2p_group_gossip_sup).

-behavior(supervisor).

-export([start_link/1, init/1]).

start_link(TID) ->
    supervisor:start_link(?MODULE, [TID]).


init([TID]) ->
    SupFlags = #{strategy => one_for_all},
    ChildSpecs =
        [
         #{ id => server,
            start => {libp2p_group_gossip_server, start_link, [TID]}
          },
         #{ id => seed_workers,
            start => {libp2p_group_gossip_worker_sup, start_link, []},
            type => supervisor
          }
        ],
    {ok, {SupFlags, ChildSpecs}}.
