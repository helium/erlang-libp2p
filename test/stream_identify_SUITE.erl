-module(stream_identify_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     identify_test
    ].


init_per_testcase(_, Config) ->
    init_streams(init_common(Config)).

end_per_testcase(_, Config) ->
    test_util:teardown_sock_pair(Config).


init_common(Config) ->
    test_util:setup(),
    test_util:setup_sock_pair(Config).

init_streams(Config) ->
    {CSock, SSock} = ?config(client_server, Config),

    #{ secret := Secret, public := Public } = libp2p_crypto:generate_keys(ed25519),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(Public),
    SigFun = libp2p_crypto:mk_sig_fun(Secret),
    Peer = libp2p_peer:from_map(
             #{
               pubkey => PubKeyBin,
               listen_addrs => ["/ip4/8.8.8.8/tcp/5678"],
               connected => [],
               nat_type => unknown
             }, SigFun),
    ServerOpts = #{
                   sig_fn => SigFun,
                   peer => Peer
                  },
    Handlers = [{<<"identify/1.0.0">>, {libp2p_stream_identify, ServerOpts}}],
    {ok, SPid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                        mod => libp2p_stream_mplex,
                                                        mod_opts => #{ handlers => Handlers }
                                                       }),
    gen_tcp:controlling_process(SSock, SPid),

    %% Client muxer
    {ok, CPid} = libp2p_stream_tcp:start_link(client, #{socket => CSock,
                                                        mod => libp2p_stream_mplex
                                                       }),
    gen_tcp:controlling_process(CSock, CPid),

    [{stream_client_server, {CPid, SPid}}, {pubkey_bin, PubKeyBin} | Config].

%%
%% Tests
%%

identify_test(Config) ->
    {CMPid, _SMPid} = ?config(stream_client_server, Config),
    PubKeyBin = ?config(pubkey_bin, Config),

    libp2p_stream_identify:start(CMPid, self(), 1000),

    receive
        {handle_identify, Muxer, {ok, Identify}} ->
            ?assertEqual(Muxer, CMPid),
            ?assertEqual(PubKeyBin, libp2p_identify:pubkey_bin(Identify))
    after
        %% Failed to get a response from identify
        3000 -> ?assert(false)
    end,

    ok.
