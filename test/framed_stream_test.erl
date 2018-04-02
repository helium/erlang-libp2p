-module(framed_stream_test).

-include_lib("eunit/include/eunit.hrl").


framed_stream_test_() ->
    test_util:foreach(
      [ fun path/1,
        fun send/1,
        fun handle_info/1,
        fun handle_call/1,
        fun handle_cast/1]).

path([S1, S2]) ->
    serve_framed_stream:register(S2, "serve_frame"),
    {_Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame/hello"),

    ?assertEqual("/hello", serve_framed_stream:path(Server)),
    ok.

send([S1, S2]) ->
    serve_framed_stream:register(S2, "serve_frame"),
    {Client, Server} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    serve_framed_stream:send(Client, <<"hello">>),
    ok = test_util:wait_until(fun() -> serve_framed_stream:data(Server) == <<"hello">> end),
    ok.

handle_info([S1, S2]) ->
    serve_framed_stream:register(S2, "serve_frame"),
    {Client, _Server} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    % Noop but causes noreply path to be executed
    serve_framed_stream:info_fun(Client, fun(S) -> {noreply, S} end),
    % Stop the client
    serve_framed_stream:info_fun(Client, fun(S) -> {stop, normal, S} end),
    ok = test_util:wait_until(fun() -> is_process_alive(Client) == false end),
    ok.

handle_call([S1, S2]) ->
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
    ok.

handle_cast([S1, S2]) ->
    serve_framed_stream:register(S2, "serve_frame"),
    {C1, _} = serve_framed_stream:dial(S1, S2, "serve_frame"),

    % Try a no reply cast
    serve_framed_stream:cast_fun(C1, fun(S) -> {noreply, S} end),
    % Stop the client with a cast
    serve_framed_stream:cast_fun(C1, fun(S) -> {stop, normal, S} end),
    ?assertMatch({'EXIT', {normal, _}}, catch serve_framed_stream:call_fun(C1, fun(S) -> {stop, normal, S} end)),
    ok = test_util:wait_until(fun() -> is_process_alive(C1) == false end),
    ok.
