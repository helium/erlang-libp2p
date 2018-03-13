-module(libp2p_framed_stream).

-behavior(gen_server).


% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
% API
-export([client/3, server/3, server/4]).
% libp2p_connection
-export([send/2, recv/1, recv/2]).

-define(RECV_TIMEOUT, 5000).

-callback server(libp2p_connection:connection(), string(), ets:tab(), [any()]) ->
    no_return() |
    {error, term()}.

-callback init(server | client, libp2p_connection:connection(), [any()]) ->
    {ok, ModState :: any()} |
    {ok, Reply :: binary() | list(), ModState :: any()} |
    {stop, Reason :: term()} |
    {stop, Reason :: term(), Reply :: binary() | list()}.

-callback handle_data(server | client, binary(), any()) ->
    {resp, Reply :: binary() | list(), ModState :: any()} |
    {noresp, ModState :: any()} |
    {stop, Reason :: term(), ModState :: any()} |
    {stop, Reason :: term(), Reply :: binary() | list(), ModState :: any()}.

-callback handle_info(server | client, term(), any()) ->
    {resp, Reply :: binary() | list(), ModState :: any()} |
    {noresp, ModState :: any()} |
    {stop, Reason :: term(), ModState :: any()}.

-callback handle_call(server | client, term(), term(), any()) ->
    {reply, Reply :: term(), ModState :: any()} |
    {noreply, ModState :: any()} |
    {stop, Reason :: term(), Reply :: term(), ModState :: any()} |
    {stop, Reason :: term(), ModState :: any()}.

-callback handle_cast(server | client, term(), any()) ->
    {noreply, ModState :: any()} |
    {stop, Reason :: term(), ModState :: any()}.



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
        {ok, State} ->
            case libp2p_connection:fdset(Connection) of
                ok -> {ok, #state{kind=Kind, connection=Connection,
                                  module=Module, state=State}};
                {error, Error} -> {error, Error}
            end;
        {ok, Response, State} ->
            case send(Connection, Response) of
                {error, Error} -> {error, Error};
                ok ->
                    case libp2p_connection:fdset(Connection) of
                        ok -> {ok, #state{kind=Kind, connection=Connection,
                                          module=Module, state=State}};
                        {error, Error} -> {error, Error}
                    end
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

handle_call(Request, From, State=#state{kind=Kind, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, handle_call, 4) of
        true ->
            case Module:handle_call(Kind, Request, From, ModuleState) of
                {reply, Reply, NewModuleState} -> {reply, Reply, State#state{state=NewModuleState}};
                {noreply, NewModuleState} -> {noreply, State#state{state=NewModuleState}};
                {stop, Reason, Reply, NewModuleState} -> {stop, Reason, Reply, State#state{state=NewModuleState}};
                {stop, Reason, NewModuleState} -> {stop, Reason, State#state{state=NewModuleState}}
            end;
        false -> {reply, ok, State}
    end.

handle_cast(Request, State=#state{kind=Kind, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, handle_cast, 3) of
        true ->
            case Module:handle_cast(Kind, Request, ModuleState) of
                {noreply, NewModuleState} -> {noreply, State#state{state=NewModuleState}};
                {stop, Reason, NewModuleState} -> {stop, Reason, State#state{state=NewModuleState}}
            end;
        false -> {noreply, State}
    end.


handle_resp({resp, Data, ModuleState}, State=#state{connection=Connection}) ->
    NewState = State#state{state=ModuleState},
    case send(Connection, Data) of
        {error, Error} -> {stop, {error, Error}, NewState};
        ok ->
            case libp2p_connection:fdset(Connection) of
                ok ->
                    {noreply, NewState};
                {error, Error} ->
                    {stop, {error, Error}, NewState}
            end
    end;
handle_resp({noresp, ModuleState}, State=#state{connection=Connection}) ->
    NewState = State#state{state=ModuleState},
    case libp2p_connection:fdset(Connection) of
        ok ->
            {noreply, NewState};
        {error, closed} ->
            {stop, normal, State};
        {error, Error} ->
            {stop, {error, Error}, NewState}
    end;
handle_resp({noreply, ModuleState}, State=#state{connection=Connection}) ->
    NewState = State#state{state=ModuleState},
    case libp2p_connection:fdset(Connection) of
        ok ->
            {noreply, NewState};
        {error, closed} ->
            {stop, normal, State};
        {error, Error} ->
            {stop, {error, Error}, NewState}
    end;
handle_resp({stop, Reason, ModuleState}, State=#state{}) ->
    {stop, Reason, State#state{state=ModuleState}};
handle_resp({stop, Reason, Reply, ModuleState}, State=#state{connection=Connection}) ->
    send(Connection, Reply),
    {stop, Reason, State#state{state=ModuleState}};


handle_resp(Msg, State=#state{}) ->
    lager:error("Unhandled framed stream response ~p", [Msg]),
    {stop, {error, bad_resp}, State}.

terminate(Reason, #state{kind=Kind, connection=Connection, module=Module, state=ModuleState}) ->
    case erlang:function_exported(Module, terminate, 2) of
        true -> Module:terminate(Kind, Reason, ModuleState);
        false -> ok
    end,
    libp2p_connection:fdclr(Connection),
    libp2p_connection:close(Connection).

-spec send(libp2p_connection:connection(), binary() | list()) -> ok | {error, term()}.
send(Connection, Data) when is_list(Data) ->
    send(Connection, list_to_binary(Data));
send(_, <<>>) ->
    ok;
send(Connection, Data) ->
    Bin = <<(byte_size(Data)):32/little-unsigned-integer, Data/binary>>,
    libp2p_connection:send(Connection, Bin).


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
