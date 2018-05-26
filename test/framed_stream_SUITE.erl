-module(framed_stream_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([path_test/1, send_test/1, handle_info_test/1, handle_call_test/1, handle_cast_test/1]).


all() ->
    [ path_test
    , send_test
    , handle_info_test
    , handle_call_test
    , handle_cast_test
    ].

setup_swarms(Callbacks, Path, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame", Callbacks),
    {Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame" ++ Path),
    [{swarms, Swarms}, {serve, {Client, Server}} | Config].

init_per_testcase(send_test, Config) ->
    setup_swarms([], "", Config);
init_per_testcase(path_test, Config) ->
    setup_swarms([], "/hello", Config);
init_per_testcase(handle_info_test, Config) ->
    InfoFun = fun(_, noreply, S) ->
                      {noreply, S};
                 (_, stop, S) ->
                      {stop, normal, S}
              end,
    setup_swarms([{info_fun, InfoFun}], "", Config);
init_per_testcase(handle_call_test, Config) ->
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
    setup_swarms([{call_fun, CallFun}], "", Config);
init_per_testcase(handle_cast_test, Config) ->
    CastFun = fun(_, noreply, S) ->
                      {noreply, S};
                 (_, {noreply, Data}, S) ->
                      {noreply, S, Data};
                 (_, {stop, Reason, Data}, S) ->
                      {stop, Reason, S, Data};
                 (_, {stop, Reason}, S) ->
                      {stop, Reason, S}
              end,
    setup_swarms([{cast_fun, CastFun}], "", Config).


end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

path_test(Config) ->
    {_Client, Server} = proplists:get_value(serve, Config),
    "/hello" = serve_framed_stream:server_path(Server),
    ok.

send_test(Config) ->
    {Client, Server} = proplists:get_value(serve, Config),

    Connection = serve_framed_stream:new_connection(Client),
    libp2p_connection:send(Connection, <<"hello">>),
    ok = test_util:wait_until(fun() -> serve_framed_stream:server_data(Server) == <<"hello">> end),
    ok.

handle_info_test(Config) ->
    {_Client, Server} = proplists:get_value(serve, Config),

    % Noop but causes noreply path to be executed
    Server ! noreply,
    % Stop the server
    Server ! stop,
    ok = test_util:wait_until(fun() -> is_process_alive(Server) == false end),
    ok.

handle_call_test(Config) ->
    [Sw1, Sw2] = proplists:get_value(swarms, Config),
    {C1, S1} = proplists:get_value(serve, Config),

    %% Try addr_info
    {_, _} = libp2p_connection:addr_info(serve_framed_stream:new_connection(C1)),

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
    C3Conn = serve_framed_stream:new_connection(C3),
    open = libp2p_connection:close_state(C3Conn),
    %% Stop the client
    libp2p_connection:close(C3Conn),
    closed = libp2p_connection:close_state(C3Conn),

    ok.

handle_cast_test(Config) ->
    [Sw1, Sw2] = proplists:get_value(swarms, Config),
    {_C1, S1} = proplists:get_value(serve, Config),

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
