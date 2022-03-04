-module(framed_stream_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([path_test/1, send_test/1, send_stream_test/1, handle_info_test/1, handle_call_test/1, handle_cast_test/1]).


all() ->
    [ path_test
    , send_test
    , send_stream_test
    , handle_info_test
    , handle_call_test
    , handle_cast_test
    ].

setup_swarms(Callbacks, Path, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms([{base_dir, ?config(base_dir, Config)}]),
    serve_framed_stream:register(S2, "serve_frame", Callbacks),
    {Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame" ++ Path),
    [{swarms, Swarms}, {serve, {Client, Server}} | Config].

init_per_testcase(send_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    setup_swarms([], "", Config0);
init_per_testcase(send_stream_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    setup_swarms([], "", Config0);
init_per_testcase(path_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    setup_swarms([], "/hello", Config0);
init_per_testcase(handle_info_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    InfoFun = fun(_, noreply, S) ->
                      {noreply, S};
                 (_, stop, S) ->
                      {stop, normal, S}
              end,
    setup_swarms([{info_fun, InfoFun}], "", Config0);
init_per_testcase(handle_call_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    CallFun = fun(_, noreply, _From, S) ->
                      {noreply, S};
                 (_, {noreply, Data}, _From, S) ->
                      {noreply, S, Data};
                 (_, {reply, Reply}, _From, S) ->
                      {reply, Reply, S};
                 (_, {reply, Reply, Data}, _From, S) ->
                      {reply, Reply, S, Data};
                 (_, {stop, Reason, Reply}, _From, S) ->
                      {stop, Reason, Reply, S};
                 (_, {stop, Reason, Reply, Data}, _From, S) ->
                      {stop, Reason, Reply, S, Data};
                 (_, {stop, Reason}, _From, S) ->
                      {stop, Reason, S}
              end,
    setup_swarms([{call_fun, CallFun}], "", Config0);
init_per_testcase(handle_cast_test = TestCase, Config) ->
    Config0 = test_util:init_base_dir_config(?MODULE, TestCase, Config),
    CastFun = fun(_, noreply, S) ->
                      {noreply, S};
                 (_, {noreply, Data}, S) ->
                      {noreply, S, Data};
                 (_, {stop, Reason, Data}, S) ->
                      {stop, Reason, S, Data};
                 (_, {stop, Reason}, S) ->
                      {stop, Reason, S}
              end,
    setup_swarms([{cast_fun, CastFun}], "", Config0).


end_per_testcase(_, Config) ->
    Swarms = ?config(swarms, Config),
    test_util:teardown_swarms(Swarms).

path_test(Config) ->
    {_Client, Server} = ?config(serve, Config),
    "/hello" = serve_framed_stream:server_path(Server),
    ok.

send_test(Config) ->
    {Client, Server} = ?config(serve, Config),

    libp2p_framed_stream:send(Client, <<"hello">>),
    ok = test_util:wait_until(fun() -> serve_framed_stream:server_data(Server) == <<"hello">> end),
    ok.

send_stream_test(Config) ->
    {Client, Server} = ?config(serve, Config),

    Msg = crypto:strong_rand_bytes(rand:uniform(20)),

    libp2p_framed_stream:send(Client, {byte_size(Msg), mk_stream_fun(Msg)}),
    ok = test_util:wait_until(fun() -> serve_framed_stream:server_data(Server) == Msg end),
    ok.


mk_stream_fun(<<>>) ->
    fun() ->
            ok
    end;
mk_stream_fun(Bin) ->
    fun() ->
            <<A:1/binary, Rest/binary>> = Bin,
            {mk_stream_fun(Rest), A}
    end.

handle_info_test(Config) ->
    {_Client, Server} = ?config(serve, Config),

    % Noop but causes noreply path to be executed
    Server ! noreply,
    % Stop the server
    Server ! stop,
    ok = test_util:wait_until(fun() -> is_process_alive(Server) == false end),
    ok.

handle_call_test(Config) ->
    [Sw1, Sw2] = ?config(swarms, Config),
    {C1, S1} = ?config(serve, Config),

    %% Try addr_info
    {_, _} = libp2p_framed_stream:addr_info(C1),

    %% Try a reply
    test_reply = gen_server:call(S1, {reply, test_reply}),

    %% Try a reply with data
    test_reply = gen_server:call(S1, {reply, test_reply, <<"hello">>}),

    %% Try a noreply
    {'EXIT', {timeout, _}} = (catch gen_server:call(S1, noreply, 100)),
    %% Try a noreply with a  response
    {'EXIT', {timeout, _}} = (catch gen_server:call(S1, {noreply, <<"hello">>}, 100)),

    %% Stop the server with a reply
    test_reply = gen_server:call(S1, {stop, normal, test_reply}),
    ok = test_util:wait_until(fun() -> is_process_alive(S1) == false end),

    %% Stop the server with a reply and data
    {_, S2} = serve_framed_stream:dial(Sw1, Sw2, "serve_frame"),
    test_reply = gen_server:call(S2, {stop, normal, test_reply, <<"hello">>}),
    ok = test_util:wait_until(fun() -> is_process_alive(S2) == false end),

    {C3, _} = serve_framed_stream:dial(Sw1, Sw2, "serve_frame"),
    open = libp2p_framed_stream:close_state(C3),
    %% Stop the client
    libp2p_framed_stream:close(C3),
    closed = libp2p_framed_stream:close_state(C3),

    ok.

handle_cast_test(Config) ->
    [Sw1, Sw2] = ?config(swarms, Config),
    {_C1, S1} = ?config(serve, Config),

    %% Try a no reply cast
    ok = gen_server:cast(S1, noreply),
    %% Try a noreply with a message to the client
    gen_server:cast(S1, {noreply, <<"hello">>}),
    %% Stop the server with a cast reason
    gen_server:cast(S1, {stop, foo}),
    ok = test_util:wait_until(fun() -> is_process_alive(S1) == false end),

    %% Stop a server with a cast reason and a message
    {_, S2} = serve_framed_stream:dial(Sw1, Sw2, "serve_frame"),
    gen_server:cast(S2, {stop, foo, <<"hello">>}),
    ok = test_util:wait_until(fun() -> is_process_alive(S2) == false end),

    ok.
