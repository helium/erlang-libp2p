-module(cache_SUITE).

-export([
    all/0
    ,init_per_testcase/2
    ,end_per_testcase/2
]).

-export([
    basic/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [basic].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_, Config) ->
    test_util:setup(),
    Config.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------


%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
    Key = test,
    Value = [1, 2, 3, 4],

    {ok, Swarm} = libp2p_swarm:start(cache_basic, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),

    TID = libp2p_swarm:tid(Swarm),
    Cache = libp2p_swarm_sup:cache(TID),
    ok = libp2p_cache:insert(Cache, Key, Value),
    Value = libp2p_cache:lookup(Cache, Key),

    ok = libp2p_swarm:stop(Swarm),
    timer:sleep(2000),

    {ok, Swarm2} = libp2p_swarm:start(cache_basic, SwarmOpts),
    ok = libp2p_swarm:listen(Swarm2, "/ip4/0.0.0.0/tcp/0"),

    TID2 = libp2p_swarm:tid(Swarm2),
    Cache2 = libp2p_swarm_sup:cache(TID2),
    Value = libp2p_cache:lookup(Cache2, Key),

    ok = libp2p_swarm:stop(Swarm2),
    ok.
