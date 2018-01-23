-module(framed_stream_test).

-include_lib("eunit/include/eunit.hrl").

path_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame"),
    {_Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame/hello"),

    ?assertEqual("/hello", serve_framed_stream:path(Server)),

    test_util:teardown_swarms(Swarms).

send_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame"),
    {Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    serve_framed_stream:send(Client, <<"hello">>),
    ok = test_util:wait_until(fun() -> serve_framed_stream:data(Server) == <<"hello">> end),

    test_util:teardown_swarms(Swarms).

handle_info_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame"),
    {Client, _Server} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    % Noop but causes noreply path to be executed
    serve_framed_stream:info_fun(Client, fun(S) -> {noreply, S} end),
    % Stop the client
    serve_framed_stream:info_fun(Client, fun(S) -> {stop, normal, S} end),
    ok = test_util:wait_until(fun() -> is_process_alive(Client) == false end),

    test_util:teardown_swarms(Swarms).

handle_call_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame"),
    {C1, _} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    % Try a no response
    ?assertMatch({'EXIT', {timeout, _}}, catch serve_framed_stream:call_fun(C1, fun(S) -> {noreply, S} end)),
    % Stop the client with a reply
    ?assertEqual(test_reply, serve_framed_stream:call_fun(C1, fun(S) -> {stop, normal, test_reply, S} end)),
    ok = test_util:wait_until(fun() -> is_process_alive(C1) == false end),

    % Start another client and stop it without a reply
    {C2, _} = serve_framed_stream:dial(S1, S2, "serve_frame"),
    % Stop the other way
    ?assertMatch({'EXIT', {normal, _}}, catch serve_framed_stream:call_fun(C2, fun(S) -> {stop, normal, S} end)),
    ok = test_util:wait_until(fun() -> is_process_alive(C2) == false end),

    test_util:teardown_swarms(Swarms).

handle_cast_test() ->
    Swarms = [S1, S2] = test_util:setup_swarms(),
    serve_framed_stream:register(S2, "serve_frame"),
    {C1, _} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    % Try a no reply cast
    serve_framed_stream:cast_fun(C1, fun(S) -> {noreply, S} end),
    % Stop the client with a cast
    serve_framed_stream:cast_fun(C1, fun(S) -> {stop, normal, S} end),
    ?assertMatch({'EXIT', {normal, _}}, catch serve_framed_stream:call_fun(C1, fun(S) -> {stop, normal, S} end)),
    ok = test_util:wait_until(fun() -> is_process_alive(C1) == false end),

    test_util:teardown_swarms(Swarms).
