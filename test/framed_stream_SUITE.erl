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

dial_path(path_test) ->
    "/hello";
dial_path(_) ->
    "".

init_per_testcase(TestCase, Config) ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame"),
    {Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame" ++ dial_path(TestCase)),
    [{swarms, Swarms}, {serve, {Client, Server}} | Config].

end_per_testcase(_, Config) ->
    Swarms = proplists:get_value(swarms, Config),
    test_util:teardown_swarms(Swarms).

path_test(Config) ->
    {_Client, Server} = proplists:get_value(serve, Config),
    "/hello" = serve_framed_stream:path(Server),
    ok.

send_test(Config) ->
    {Client, Server} = proplists:get_value(serve, Config),
    serve_framed_stream:send(Client, <<"hello">>),
    ok = test_util:wait_until(fun() -> serve_framed_stream:data(Server) == <<"hello">> end),
    ok.

handle_info_test(Config) ->
    {Client, _Server} = proplists:get_value(serve, Config),

    % Noop but causes noreply path to be executed
    serve_framed_stream:info_fun(Client, fun(S) -> {noreply, S} end),
    % Stop the client
    serve_framed_stream:info_fun(Client, fun(S) -> {stop, normal, S} end),
    ok = test_util:wait_until(fun() -> is_process_alive(Client) == false end),
    ok.

handle_call_test(Config) ->
    [S1, S2] = proplists:get_value(swarms, Config),
    {C1, _} = proplists:get_value(serve, Config),

    % Try a no response
    {'EXIT', {timeout, _}} = (catch serve_framed_stream:call_fun(C1, fun(S) -> {noreply, S} end)),
    % Stop the client with a reply
    test_reply = serve_framed_stream:call_fun(C1, fun(S) -> {stop, normal, test_reply, S} end),
    ok = test_util:wait_until(fun() -> is_process_alive(C1) == false end),

    % Start another client and stop it without a reply
    {C2, _} = serve_framed_stream:dial(S1, S2, "serve_frame"),
    % Stop the other way
    {'EXIT', {normal, _}} = (catch serve_framed_stream:call_fun(C2, fun(S) -> {stop, normal, S} end)),
    ok = test_util:wait_until(fun() -> is_process_alive(C2) == false end),
    ok.

handle_cast_test(Config) ->
    {C1, _} = proplists:get_value(serve, Config),

    % Try a no reply cast
    serve_framed_stream:cast_fun(C1, fun(S) -> {noreply, S} end),
    % Stop the client with a cast
    serve_framed_stream:cast_fun(C1, fun(S) -> {stop, normal, S} end),
    {'EXIT', {normal, _}} = (catch serve_framed_stream:call_fun(C1, fun(S) -> {stop, normal, S} end)),
    ok = test_util:wait_until(fun() -> is_process_alive(C1) == false end),
    ok.
