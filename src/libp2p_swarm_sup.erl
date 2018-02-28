-module(libp2p_swarm_sup).

-behaviour(supervisor).

% supervisor
-export([init/1]).
% api
-export([server/1, sup/1]).

-define(SUP, swarm_sup).
-define(SERVER, swarm_server).

init([]) ->
    inert:start(),
    TID = ets:new(config, [public, ordered_set, {read_concurrency, true}]),
    ets:insert(TID, {?SUP, self()}),
    SupFlags = {one_for_all, 3, 10},
    ChildSpecs = [
                  {listeners,
                   {libp2p_swarm_listener_sup, start_link, [TID]},
                   permanent,
                   10000,
                   supervisor,
                   [libp2p_swarm_listener_sup]
                  },
                  {sessions,
                   {libp2p_swarm_session_sup, start_link, [TID]},
                   permanent,
                   10000,
                   supervisor,
                   [libp2p_swarm_session_sup]
                  },
                  {transports,
                   {libp2p_swarm_transport_sup, start_link, [TID]},
                   permanent,
                   10000,
                   supervisor,
                   [libp2p_swarm_transport_sup]
                  },
                  {?SERVER,
                   {libp2p_swarm_server, start_link, [TID]},
                   permanent,
                   10000,
                   worker,
                   [libp2p_swarm_server]
                  }
                 ],
    {ok, {SupFlags, ChildSpecs}}.

-spec sup(ets:tab()) -> supervisor:sup_ref().
sup(TID) ->
    ets:lookup_element(TID, ?SUP, 2).

-spec server(supervisor:sup_ref()) -> libp2p_swarm_server:ref().
server(Sup) ->
    Children = supervisor:which_children(Sup),
    {?SERVER, Pid, _, _} = lists:keyfind(?SERVER, 1, Children),
    Pid.
