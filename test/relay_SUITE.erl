-module(relay_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

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
    lager:set_loglevel(lager_console_backend, info),
    {ok, Swarm} = libp2p_swarm:start(?MODULE, [{libp2p_transport_tcp, [{nat, false}]}]),
    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
    [Addr] = libp2p_swarm:listen_addrs(Swarm),
    [{swarm, Swarm}, {addr, Addr} | Config].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, Config) ->
    Swarm = proplists:get_value(swarm, Config),
    test_util:teardown_swarms([Swarm]).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(Config) ->
    Addr = proplists:get_value(addr, Config),
    lager:notice("address ~p", [Addr]),

    {ok, Swarm} = libp2p_swarm:start(basic, [{libp2p_transport_tcp, [{nat, false}]}]),
    % erlang:spawn(fun() ->
    %     _ = erlang:monitor(process, Swarm),
    %     receive
    %         Msg ->
    %             lager:warning("[~p:~p:~p] MARKER ~p", [?MODULE_STRING, ?FUNCTION_NAME, ?LINE, Msg])
    %     end
    % end),

    ok = libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_relay:dial(Swarm, Addr, []),
    timer:sleep(2000),
    lager:warning("[~p:~p:~p] MARKER ~p", [?MODULE, ?FUNCTION_NAME, ?LINE, libp2p_swarm:listen_addrs(Swarm)]),
    ok.



%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
