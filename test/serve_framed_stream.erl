-module(serve_framed_stream).
-behaviour(libp2p_framed_stream).

-export([register/2, init/3, handle_info/3, handle_data/3, handle_call/4, handle_cast/3,
         dial/3, path/1, send/2, send/3, data/1, info_fun/2, call_fun/2, cast_fun/2]).

-record(state, {
          parent=undefined :: pid() | undefined,
          path=undefined :: binary() | undefined,
          connection :: libp2p_connection:connection(),
          data=undefined :: binary() | undefined
         }).

register(Swarm, Name) ->
    libp2p_swarm:add_stream_handler(Swarm, Name, {libp2p_framed_stream, server, [?MODULE, self()]}).

dial(FromSwarm, ToSwarm, Name) ->
    Stream = test_util:dial(FromSwarm, ToSwarm, Name),
    Server = receive
                 {hello_server, S} -> S
             after 100 -> erlang:exit(timeout)
             end,
    {ok, Client} = libp2p_framed_stream:client(?MODULE, Stream, []),
    {Client, Server}.


init(server, Connection, [Path, Parent]) ->
    Parent ! {hello_server, self()},
    {ok, #state{connection=Connection, path=Path, parent=Parent}};
init(client, Connection, []) ->
    {ok, #state{connection=Connection}};
init(client, Connection, [Parent]) ->
    Parent ! {hello_client, self()},
    {ok, #state{connection=Connection}}.


handle_data(_, Data, State=#state{}) ->
    {noresp, State#state{data=Data}}.

handle_info(_, {fn, Fun}, State=#state{}) ->
    Fun(State).

handle_call(_, {send, Bin, Timeout}, _From, State=#state{connection=Connection}) ->
    Result = libp2p_framed_stream:send(Connection, Bin, Timeout),
    {reply, Result, State};
handle_call(_, path, _From, State=#state{path=Path}) ->
    {reply, Path, State};
handle_call(_, data, _From, State=#state{data=Data}) ->
    {reply, Data, State};
handle_call(_, {fn, Fun}, _From, State=#state{}) ->
    Fun(State).

handle_cast(_, {fn, Fun}, State=#state{}) ->
    Fun(State).


path(Pid) ->
    gen_server:call(Pid, path).

data(Pid) ->
    gen_server:call(Pid, data).

send(Pid, Bin) ->
    send(Pid, Bin, 1000).

send(Pid, Bin, Timeout) ->
    gen_server:call(Pid, {send, Bin, Timeout}).

info_fun(Pid, Fun) ->
    Pid ! {fn, Fun}.

call_fun(Pid, Fun) ->
    call_fun(Pid, Fun, 100).

call_fun(Pid, Fun, Timeout) ->
    gen_server:call(Pid, {fn, Fun}, Timeout).

cast_fun(Pid, Fun) ->
    gen_server:cast(Pid, {fn, Fun}).
