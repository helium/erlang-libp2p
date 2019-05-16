-module(transport_tcp_listen_SUITE).


-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     listen_port0_test,
     reuse_port0_test,
     listen_ip_test,
     listen_port_test
    ].


init_per_testcase(listen_ip_test, Config) ->
    TmpDir = test_util:nonl(os:cmd("mktemp -d")),
    [{cache_dir, TmpDir} | Config];
init_per_testcase(_, Config) ->
    test_util:setup(),
    TmpDir = test_util:nonl(os:cmd("mktemp -d")),
    Pid = mk_listener(TmpDir),
    [{listener_sup, Pid}, {cache_dir, TmpDir} | Config].

mk_listener(TmpDir) ->
    mk_listener({0, 0, 0, 0}, TmpDir).

mk_listener(IP, TmpDir) ->
    mk_listener(IP, 0, TmpDir).

mk_listener(IP, Port, TmpDir) ->
    HandlerFun = fun() ->
                         [{"mplex/1.0.0", {no_mplex_mod, no_mplex_opts}}]
                 end,
    {ok, Pid} = libp2p_transport_tcp_listen_sup:start_link(IP, Port,
                                                           #{cache_dir => TmpDir,
                                                             handler_fn => HandlerFun}),
    Pid.



%%
%% Tests
%%

listen_port0_test(Config) ->
    Pid = ?config(listener_sup, Config),

    ListenAddrs = libp2p_transport_tcp_listen_sup:listen_addrs(Pid),
    ?assert(length(ListenAddrs) > 0),

    [{IP, Port} | _] = ListenAddrs,
    {ok, CSock} = gen_tcp:connect(IP, Port, [binary, {active, false}]),

    handshake(client, CSock),

    exit(Pid, normal),

    ?assert(test_util:pid_should_die(Pid)),
    ok.

reuse_port0_test(Config) ->
    Pid = ?config(listener_sup, Config),

    [{_, Port} | _] = libp2p_transport_tcp_listen_sup:listen_addrs(Pid),
    exit(Pid, normal),
    ?assert(test_util:pid_should_die(Pid)),

    TmpDir = ?config(cache_dir, Config),
    NewPid = mk_listener(TmpDir),
    [{_, NewPort} | _] = libp2p_transport_tcp_listen_sup:listen_addrs(NewPid),

    ?assertEqual(Port, NewPort),

    exit(NewPid, normal),
    ?assert(test_util:pid_should_die(NewPid)),

    ok.

listen_ip_test(Config) ->
    TmpDir = ?config(cache_dir, Config),

    %% Get one of our local ip addresse
    [IPAddr | _] = libp2p_transport_tcp_listen_socket:get_non_local_addrs(),

    %% Make a listener and find out the address an dport
    Pid = mk_listener(IPAddr, TmpDir),
    [{ListenAddr, ListenPort} | _] = libp2p_transport_tcp_listen_sup:listen_addrs(Pid),
    ?assertEqual(IPAddr, ListenAddr),

    exit(Pid, normal),
    ?assert(test_util:pid_should_die(Pid)),

    %% Restart the listener with the same cache and ip address
    NewPid = mk_listener(IPAddr, TmpDir),
    %% And verify the port was reused
    ?assertMatch([{ListenAddr, ListenPort} | _ ], libp2p_transport_tcp_listen_sup:listen_addrs(NewPid)),

    exit(NewPid, normal),
    ?assert(test_util:pid_should_die(NewPid)),

    ok.

listen_port_test(Config) ->
    TmpDir = ?config(cache_dir, Config),

    %% Get one of our local ip addresse
    [IPAddr | _] = libp2p_transport_tcp_listen_socket:get_non_local_addrs(),
    Port = 53432,

    %% Make a listener and find out the address an dport
    Pid = mk_listener(IPAddr, Port, TmpDir),
    [{ListenAddr, ListenPort} | _] = libp2p_transport_tcp_listen_sup:listen_addrs(Pid),
    ?assertEqual({IPAddr, Port}, {ListenAddr, ListenPort}),

    %% Restart the listener with the same cache and ip address
    NewPid = mk_listener(IPAddr, Port, TmpDir),
    %% And verify the port was reused
    ?assertMatch([{ListenAddr, ListenPort} | _ ], libp2p_transport_tcp_listen_sup:listen_addrs(NewPid)),

    exit(NewPid, normal),
    ?assert(test_util:pid_should_die(NewPid)),

    ok.






%%
%% Utilities
%%

handshake(client, Sock) ->
    %% receive server handshake
    ProtocolId = libp2p_stream_multistream:protocol_id(),
    HandshakeSize = byte_size(libp2p_stream_multistream:encode_line(ProtocolId)),
    ?assertEqual(ProtocolId, receive_line(Sock, HandshakeSize)),
    %% Send client handshake
    send_line(Sock, ProtocolId).

send_line(Sock, Line) ->
    Bin = libp2p_stream_multistream:encode_line(Line),
    ok = gen_tcp:send(Sock, Bin).

receive_line(Sock) ->
    receive_line(Sock, 0).

receive_line(Sock, Size) ->
    {ok, Bin} = gen_tcp:recv(Sock, Size, 500),
    {Line, _Rest} = libp2p_stream_multistream:decode_line(Bin),
    Line.
