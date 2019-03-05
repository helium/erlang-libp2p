-module(libp2p_secure_framed_stream_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
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
init_per_testcase(_, _Config) ->
    test_util:setup(),
    lager:set_loglevel(lager_console_backend, info),
    _Config.

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
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    Version = "securetest/1.0.0",

    {ok, ServerSwarm} = libp2p_swarm:start(secure_server_test, SwarmOpts),
    ok = libp2p_swarm:listen(ServerSwarm, "/ip4/0.0.0.0/tcp/0"),
    libp2p_swarm:add_stream_handler(
        ServerSwarm,
        Version,
        {libp2p_framed_stream, server, [libp2p_secure_framed_stream_test, self(), ServerSwarm]}
    ),

    {ok, ClientSwarm} = libp2p_swarm:start(secure_client_test, SwarmOpts),
    ok = libp2p_swarm:listen(ClientSwarm, "/ip4/0.0.0.0/tcp/0"),

    [ServerAddress|_] = libp2p_swarm:listen_addrs(ServerSwarm),
    {ok, ClientStream} = libp2p_swarm:dial_framed_stream(
        ClientSwarm,
        ServerAddress,
        Version,
        libp2p_secure_framed_stream_test,
        [ClientSwarm, self()]
    ),

    ok = test_util:wait_until(fun() -> true =:= gen_server:call(ClientStream, exchanged) end),
    ?assert(gen_server:call(ClientStream, exchanged)),

    lists:foreach(
        fun(_) ->
            Data = crypto:strong_rand_bytes(16),
            ClientStream ! {send, Data},
            receive
                {echo, server, Data} -> ok;
                _Else -> ct:fail(_Else)
            after 250 ->
                ct:fail(timeout)
            end
        end,
        lists:seq(1, 100)
    ),

    ok = libp2p_swarm:stop(ServerSwarm),
    ok = libp2p_swarm:stop(ClientSwarm),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------