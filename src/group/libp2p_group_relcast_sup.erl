-module(libp2p_group_relcast_sup).

-behavior(supervisor).

%% API
-export([start_link/3, workers/1, server/1]).
%% supervisor
-export([init/1]).

-define(SERVER, server).
-define(WORKERS, workers).

start_link(TID, Handler, Args) ->
    supervisor:start_link(?MODULE, [Handler, Args, TID]).

init([Handler, Args, TID]) ->
    SupFlags = #{strategy => one_for_all},
    ChildSpecs =
        [
         #{ id => ?WORKERS,
            start => {libp2p_group_worker_sup, start_link, []},
            type => supervisor
          },
         #{ id => server,
            start => {libp2p_group_relcast_server, start_link, [Handler, Args, self(), TID]}
          }
        ],
    {ok, {SupFlags, ChildSpecs}}.

server(Sup) ->
    Children = supervisor:which_children(Sup),
    {?SERVER, Pid, _, _} = lists:keyfind(?SERVER, 1, Children),
    Pid.

workers(Sup) ->
    Children = supervisor:which_children(Sup),
    {?WORKERS, Pid, _, _} = lists:keyfind(?WORKERS, 1, Children),
    Pid.
