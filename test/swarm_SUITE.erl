-module(swarm_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([accessor_test/1, stop_test/1, dial_self/1]).

all() ->
    [
        accessor_test,
        stop_test,
        dial_self
    ].

init_per_testcase(TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    Swarms = test_util:setup_swarms(1, [{base_dir, ?config(base_dir, Config0)}]),
    [{swarms, Swarms} | Config0].

end_per_testcase(stop_test, _Config) ->
    ok;
end_per_testcase(_, Config) ->
    Swarms = ?config(swarms, Config),
    test_util:teardown_swarms(Swarms).

%% Tests
%%

accessor_test(Config) ->
    [S1] = ?config(swarms, Config),

    {ok, PubKey, _, _} = libp2p_swarm:keys(S1),
    true = libp2p_crypto:pubkey_to_bin(PubKey) == libp2p_swarm:pubkey_bin(S1),
    case libp2p_swarm:opts(S1) of
        [{libp2p_nat, [{enabled, false}]}, {data_dir, _}, {base_dir, _}] -> ok;
        [{base_dir, _}, {libp2p_nat, [{enabled, false}]}] -> ok
    end,
    "swarm" ++ _ = atom_to_list(libp2p_swarm:name(S1)),

    ok.

stop_test(Config) ->
    [S1] = ?config(swarms, Config),

    libp2p_swarm:stop(S1),
    true = libp2p_swarm:is_stopping(S1),

    ok.


dial_self(Config) ->
    [Swarm] = ?config(swarms, Config),
    Version = "proxytest/1.0.0",
    libp2p_swarm:add_stream_handler(
        Swarm
        ,Version
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy_test, self(), Swarm]}
    ),
    Addrs = [Address|_] = libp2p_swarm:listen_addrs(Swarm),
    ct:pal("Addrs: ~p", [Addrs]),

    {error, dialing_self} = libp2p_swarm:dial_framed_stream(
        Swarm
        ,Address
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    timer:sleep(100),
    %% when using the p2p address, it will result in all listen addrs being pulled from the peerbook
    %% and each will be interated over resulting in a dialing_self error for each
    {error, Result} = libp2p_swarm:dial_framed_stream(
        Swarm
        ,libp2p_swarm:p2p_address(Swarm)
        ,Version
        ,libp2p_stream_proxy_test
        ,[{echo, self()}]
    ),
    S1 = sets:from_list(Result),
    S2 = sets:from_list([{A, dialing_self} || A <- Addrs]),
    [] = sets:to_list(sets:subtract(S1, S2)),
    ok.
