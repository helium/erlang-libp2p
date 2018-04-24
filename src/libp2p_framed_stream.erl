-module(libp2p_framed_stream).

-behavior(gen_server).


% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
% API
-export([client/3, server/3, server/4]).
% libp2p_connection
-export([send/2, send/3, recv/1, recv/2]).

-define(RECV_TIMEOUT, 5000).

-type response() :: binary().
-type handle_data_result() ::
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type init_result() ::
        {ok, ModState :: any()} |
        {ok, ModState :: any(), Response::response()} |
        {stop, Reason :: term()} |
        {stop, Reason :: term(), Response::response()}.
-type handle_info_result() ::
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type handle_call_result() ::
        {reply, Reply :: term(), ModState :: any()} |
        {reply, Reply :: term(), ModState :: any(), Response::response()} |
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), Reply :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), Reply :: term(), ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.
-type handle_cast_result() ::
        {noreply, ModState :: any()} |
        {noreply, ModState :: any(), Response::response()} |
        {stop, Reason :: term(), ModState :: any()} |
        {stop, Reason :: term(), ModState :: any(), Response::response()}.

-export_type([init_result/0,
              handle_info_result/0,
              handle_call_result/0,
              handle_cast_result/0,
              handle_data_result/0]).

-callback server(libp2p_connection:connection(), string(), ets:tab(), [any()]) ->
    no_return() |
    {error, term()}.

-callback init(server | client, libp2p_connection:connection(), [any()]) -> init_result().
-callback handle_data(server | client, binary(), any()) -> handle_data_result().
-callback handle_info(server | client, term(), any()) -> handle_info_result().
-callback handle_call(server | client, Msg::term(), From::term(), ModState::any()) -> handle_call_result().
-callback handle_cast(server | client, term(), any()) -> handle_cast_result().

-optional_callbacks([server/4, handle_info/3, handle_call/4, handle_cast/3]).

-record(state, {
          module :: atom(),
          state :: any(),
          kind :: server | client,
          connection :: libp2p_connection:connection()
         }).

%%
%% Client
%%

-spec client(atom(), libp2p_connection:connection(), [any()]) -> {ok, pid()} | {error, term()} | ignore.
client(Module, Connection, Args) ->
    case gen_server:start(?MODULE, {client, Module, Connection, Args}, []) of
        {ok, Pid} ->
            libp2p_connection:controlling_process(Connection, Pid),
            {ok, Pid};
        {error, Error} -> {error, Error};
        Other -> Other
    end.

init({client, Module, Connection, Args}) ->
    case init_module(client, Module, Connection, Args) of
        {ok, State} -> {ok, State};
        {error, Error} -> {stop, Error}
    end.


%%
%% Server
%%
-spec server(atom(), libp2p_connection:connection(), [any()]) -> no_return() | {error, term()}.
server(Module, Connection, Args) ->
    case init_module(server, Module, Connection, Args) of
        {ok, State} -> gen_server:enter_loop(?MODULE, [], State);
        {error, Error} -> {error, Error}
    end.

server(Connection, Path, _TID, [Module | Args]) ->
    server(Module, Connection, [Path | Args]).

%%
%% Common
%%

-spec init_module(atom(), atom(), libp2p_connection:connection(), [any()]) -> {ok, #state{}} | {error, term()}.
init_module(Kind, Module, Connection, Args) ->
    case Module:init(Kind, Connection, Args) of
        {ok, ModuleState} ->
            case handle_fd_set(#state{kind=Kind, connection=Connection,
                                  module=Module, state=ModuleState}) of
                {ok, S} -> {ok, S};
                {error, Error, _S} -> {error, Error}
            end;
        {ok, ModuleState, Response} ->
            case handle_resp_send(Response, #state{kind=Kind, connection=Connection,
                                                   module=Module, state=ModuleState}) of
                {ok, S} -> {ok, S};
                {error, Error, _S} -> {error, Error}
            end;
        {stop, Reason} ->
            libp2p_connection:close(Connection),
            {error, Reason};
        {stop, Reason, Response} ->
            Res = case send(Connection, Response) of
                {error, Error} -> {error, Error};
                ok -> {error, Reason}
            end,
            libp2p_connection:close(Connection),
            Res
    end.


handle_info({inert_read, _, _}, State=#state{kind=Kind, connection=Connection,
                                             module=Module, state=ModuleState}) ->
    case recv(Connection, ?RECV_TIMEOUT) of
        {error, timeout} ->
            %% timeouts are fine and not an error we want to propogate because there's no waiter
            {noreply, State};
        {error, closed} ->
            %% This attempts to avoid a large number of errored stops
            %% when a connection is closed, which happens "normally"
            %% in most cases.
            {stop, normal, State};
        {error, Error}  ->
            lager:info("framed inert RECV ~p, ~p", [Error, Connection]),
            {stop, {error, Error}, State};
        {ok, Bin} -> handle_resp(Module:handle_data(Kind, Bin, ModuleState), State)
    end;
handle_info(Msg, State=#state{kind=Kind, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, handle_info, 3) of
        true -> handle_resp(Module:handle_info(Kind, Msg, ModuleState), State);
        false -> {noreply, State}
    end.

handle_call(Msg, From, State=#state{kind=Kind, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, handle_call, 4) of
        true -> handle_resp(Module:handle_call(Kind, Msg, From, ModuleState), State);
        false -> [reply, ok, State]
    end.

handle_cast(Request, State=#state{kind=Kind, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, handle_cast, 3) of
        true -> handle_resp(Module:handle_cast(Kind, Request, ModuleState), State);
        false -> {noreply, State}
    end.

terminate(Reason, #state{kind=Kind, connection=Connection, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, terminate, 2) of
        true -> Module:terminate(Kind, Reason, ModuleState);
        false -> ok
    end,
    libp2p_connection:fdclr(Connection),
    libp2p_connection:close(Connection).

-spec send(libp2p_connection:connection(), binary(), pos_integer()) -> ok | {error, term()}.
send(_, <<>>, _) ->
    ok;
send(Connection, Data, Timeout) ->
    Bin = <<(byte_size(Data)):32/little-unsigned-integer, Data/binary>>,
    libp2p_connection:send(Connection, Bin, Timeout).

-spec send(libp2p_connection:connection(), binary()) -> ok | {error, term()}.
send(Connection, Data) ->
    send(Connection, Data, 5000).

-spec recv(libp2p_connection:connection()) -> {ok, binary()} | {error, term()}.
recv(Connection) ->
    recv(Connection, ?RECV_TIMEOUT).

-spec recv(libp2p_connection:connection(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
recv(Connection, Timeout) ->
    case libp2p_connection:recv(Connection, 4, Timeout) of
        {error, Error} -> {error, Error};
        {ok, <<Size:32/little-unsigned-integer>>} ->
            %% TODO: Limit max message size we're willing to
            %% TODO if we read the prefix length, but time out on the payload, we should handle this?
            case libp2p_connection:recv(Connection, Size, Timeout) of
                {ok, Data} when byte_size(Data) == Size -> {ok, Data};
                {ok, _Data} -> error(frame_size_mismatch);
                {error, Error} -> {error, Error}
            end
    end.

%% Internal
%%

-spec handle_resp_send(binary(), State) -> {ok, State} | {error, term()} when State::#state{}.
handle_resp_send(Data, State=#state{connection=Connection}) ->
    case send(Connection, Data) of
        {error, Error} -> {error, Error, State};
        ok -> handle_fd_set(State)
    end.

-spec handle_fd_set(State) -> {ok, State} | {error, term(), State} when State::#state{}.
handle_fd_set(State=#state{connection=Connection}) ->
    case libp2p_connection:fdset(Connection) of
        ok -> {ok, State};
        {error, Error} -> {error, Error, State}
    end.

handle_resp({reply, Reply, ModuleState}, State=#state{}) ->
    {reply, Reply, State#state{state=ModuleState}};
handle_resp({reply, Reply, ModuleState, Response}, State=#state{}) ->
    case handle_resp_send(Response, State#state{state=ModuleState}) of
        {ok, NewState} -> {reply, Reply, NewState};
        {error, closed, NewState} -> {stop, normal, Reply, NewState};
        {error, Error, NewState} -> {stop, {error, Error}, NewState}
    end;

handle_resp({noreply, ModuleState}, State=#state{}) ->
    {noreply, State#state{state=ModuleState}};
handle_resp({noreply, ModuleState, Response}, State=#state{}) ->
    case handle_resp_send(Response, State#state{state=ModuleState}) of
        {ok, NewState} -> {noreply, NewState};
        {error, closed, NewState} -> {stop, normal, NewState};
        {error, Error, NewState} -> {stop, {error, Error}, NewState}
    end;

handle_resp({stop, Reason, ModuleState, Response}, State=#state{}) when is_binary(Response) ->
    case handle_resp_send(Response, State#state{state=ModuleState}) of
        {ok, NewState} -> {stop, Reason, NewState};
        {error, closed, NewState} -> {stop, normal, NewState};
        {error, Error, NewState} -> {stop, {error, Error}, NewState}
    end;
handle_resp({stop, Reason, Reply, ModuleState}, State=#state{}) ->
    {stop, Reason, Reply, State#state{state=ModuleState}};
handle_resp({stop, Reason, ModuleState}, State=#state{}) ->
    {stop, Reason, State#state{state=ModuleState}};
handle_resp({stop, Reason, Reply, ModuleState, Response}, State=#state{}) ->
    case handle_resp_send(Response, State#state{state=ModuleState}) of
        {ok, NewState} -> {stop, Reason, Reply, NewState};
        {error, closed, NewState} -> {stop, normal, NewState};
        {error, Error, NewState} -> {stop, {error, Error}, NewState}
    end;
handle_resp(Msg, State=#state{}) ->
    lager:error("Unhandled framed stream response ~p", [Msg]),
    {stop, {error, bad_resp}, State}.
