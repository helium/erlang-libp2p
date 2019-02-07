-module(swarm_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accessor_test/1, stop_test/1, dial_self/1]).

all() ->
    [
        accessor_test,
        stop_test,
        dial_self
    ].

init_per_testcase(_, Config) ->
    Swarms = test_util:setup_swarms(1, []),
    [{swarms, Swarms} | Config].

end_per_testcase(stop_test, _Config) ->
    ok;
end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

%% Tests
%%

accessor_test(Config) ->
    [S1] = proplists:get_value(swarms, Config),

    {ok, PubKey, _} = libp2p_swarm:keys(S1),
    true = libp2p_crypto:pubkey_to_bin(PubKey) == libp2p_swarm:pubkey_bin(S1),

    [{base_dir, _}, {libp2p_nat, [{enabled, false}]}] = libp2p_swarm:opts(S1),
    "swarm" ++ _ = atom_to_list(libp2p_swarm:name(S1)),

    ok.

stop_test(Config) ->
    [S1] = proplists:get_value(swarms, Config),

    libp2p_swarm:stop(S1),
    true = libp2p_swarm:is_stopping(S1),

    ok.


dial_self(Config) ->
    [Swarm] = proplists:get_value(swarms, Config),
    Version = "proxytest/1.0.0",
    libp2p_swarm:add_stream_handler(
        Swarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), Swarm]}
    ),
    [Address|_] = libp2p_swarm:listen_addrs(Swarm),
    {error, dialing_self} = libp2p_swarm:dial_framed_stream(
        Swarm
        ,Address
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    ok.
