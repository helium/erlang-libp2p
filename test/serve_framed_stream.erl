-module(serve_framed_stream).
-behaviour(libp2p_framed_stream).

-export([register/3, dial/3, new_connection/1, server_path/1, server_data/1]).
%% libp2p_framed_stream
-export([client/2, server/4, init/3, handle_info/3, handle_data/3, handle_call/4, handle_cast/3]).

-record(state,
        { parent=undefined :: pid() | undefined,
          path=undefined :: binary() | undefined,
          connection :: libp2p_connection:connection(),
          data=undefined :: binary() | undefined,
          info_fun :: undefined
                    | fun((libp2p_framed_stream:kind(), term(), #state{})
                          -> libp2p_framed_stream:handle_info_result()),
          call_fun :: undefined
                    | fun((libp2p_framed_stream:kind(), Msg::term(), From::term(), #state{})
                          -> libp2p_framed_stream:handle_call_result()),
          cast_fun :: undefined
                    | fun((libp2p_framed_stream:kind(), term(), #state{})
                          -> libp2p_framed_stream:handle_info_result())
         }).

register(Swarm, Name, Callbacks) ->
    libp2p_swarm:add_stream_handler(Swarm, Name, {libp2p_framed_stream, server, [?MODULE, self(), Callbacks]}).

dial(FromSwarm, ToSwarm, Name) ->
    Connection = test_util:dial(FromSwarm, ToSwarm, Name),
    Server = receive
                 {hello_server, S} -> S
             after 100 -> erlang:exit(timeout)
             end,
    {ok, Stream} = client(Connection, []),
    {Stream, Server}.

new_connection(Client) ->
    libp2p_framed_stream:new_connection(Client).

init_callbacks(Callbacks, State=#state{}) ->
    InfoFun = proplists:get_value(info_fun, Callbacks, undefined),
    CastFun = proplists:get_value(cast_fun, Callbacks, undefined),
    CallFun = proplists:get_value(call_fun, Callbacks, undefined),
    State#state{info_fun=InfoFun, call_fun=CallFun, cast_fun=CastFun}.

%%
%% libp2p_framed_stream
%%

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(server, Connection, [Path, Parent, Callbacks]) ->
    Parent ! {hello_server, self()},
    {ok, init_callbacks(Callbacks, #state{connection=Connection, path=Path, parent=Parent})};
init(client, Connection, []) ->
    {ok, #state{connection=Connection}};
init(client, Connection, [Parent]) ->
    Parent ! {hello_client, self()},
    {ok, #state{connection=Connection}}.


handle_data(_, Data, State=#state{}) ->
    {noreply, State#state{data=Data}}.

handle_info(_Kind, _Msg, State=#state{info_fun=undefined}) ->
    {noreply, State};
handle_info(Kind, Msg, State=#state{info_fun=InfoFun}) ->
    InfoFun(Kind, Msg, State).

handle_call(server, data, _From, State=#state{data=Data}) ->
    {reply, Data, State};
handle_call(server, path, _From, State=#state{path=Path}) ->
    {reply, Path, State};
handle_call(_Kind, Msg, _From,  State=#state{call_fun=undefined}) ->
    {reply, {error, no_callback, Msg}, State};
handle_call(Kind, Msg, From, State=#state{call_fun=CallFun}) ->
    CallFun(Kind, Msg, From, State).

handle_cast(_Kind, _Msg, State=#state{cast_fun=undefined}) ->
    {noreply, State};
handle_cast(Kind, Msg, State=#state{cast_fun=CastFun}) ->
    CastFun(Kind, Msg, State).


server_path(Pid) ->
    gen_server:call(Pid, path).

server_data(Pid) ->
    gen_server:call(Pid, data).
