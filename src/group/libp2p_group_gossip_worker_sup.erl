-module(libp2p_group_gossip_worker_sup).

-behavior(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).


init([]) ->
    SupFlags = #{strategy => one_for_one},
    {ok, {SupFlags, []}}.
