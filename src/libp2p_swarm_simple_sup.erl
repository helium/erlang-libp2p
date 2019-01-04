-module(libp2p_swarm_simple_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/1,
    register_peerbook/1, peerbook/1,
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
-define(PEERBOOK, swarm_peerbook).
-define(CACHE, swarm_cache).

%%====================================================================
%% API functions
%%====================================================================
start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

register_peerbook(TID) ->
    ets:insert(TID, {?PEERBOOK, self()}).

-spec peerbook(ets:tab()) -> pid().
peerbook(TID) ->
    ets:lookup_element(TID, ?PEERBOOK, 2).

register_cache(TID) ->
    ets:insert(TID, {?CACHE, self()}).

-spec cache(ets:tab()) -> pid().
cache(TID) ->
    ets:lookup_element(TID, ?CACHE, 2).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([TID, SigFun, Opts]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },
    Specs = [
        ?WORKER(?PEERBOOK, libp2p_peerbook, [TID, SigFun]),
        ?WORKER(?CACHE, libp2p_cache, [TID]),
        ?WORKER(relay, libp2p_relay_server, [TID]),
        ?WORKER(proxy, libp2p_proxy_server, [[TID, libp2p_proxy:limit(Opts)]])
    ],
    {ok, {SupFlags, Specs}}.

%%====================================================================
%% Internal functions
%%====================================================================
