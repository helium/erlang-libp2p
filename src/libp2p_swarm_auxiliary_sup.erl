-module(libp2p_swarm_auxiliary_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/1,
    register_cache/1, cache/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(WORKER(ID, Mod, Args), #{
    id => ID,
    start => {Mod, start_link, Args},
    restart => permanent,
    shutdown => 1000,
    type => worker,
    modules => [Mod]
}).

-define(CACHE, swarm_cache).

%%====================================================================
%% API functions
%%====================================================================
start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

register_cache(TID) ->
    ets:insert(TID, {?CACHE, self()}).

-spec cache(ets:tab()) -> pid().
cache(TID) ->
    ets:lookup_element(TID, ?CACHE, 2).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([TID, Opts]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },
    Specs = [
        ?WORKER(relay, libp2p_relay_server, [TID]),
        ?WORKER(proxy, libp2p_proxy_server, [[TID, libp2p_proxy:limit(Opts)]])
    ],
    {ok, {SupFlags, Specs}}.

%%====================================================================
%% Internal functions
%%====================================================================
