-module(libp2p_framed_stream).

-behavior(gen_server).


% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
% API
-export([enter_loop/3]).
% libp2p_connection
-export([send/2, recv/1, recv/2]).

-define(RECV_TIMEOUT, 5000).

-callback enter_loop(libp2p_connection:connection(), string(), ets:tab(), [any()]) -> {ok, term()} | {stop, term()}.
-callback init([any()]) -> {ok, any()} |
                           {ok, binary() | list(), any()} |
                           {stop, term()} |
                           {stop, term(), binary() | list()}.
-callback handle_data(binary(), any()) -> {resp, binary() | list(), any()} |
                                          noresp |
                                          {noresp, any()} |
                                          {stop, term(), any()}.

-record(state, {
          module :: atom(),
          state :: any(),
          connection :: libp2p_connection:connection()
         }).

mk_state(Connection, Module, ModuleState) ->
    #state{connection=Connection, module=Module, state=ModuleState}.

-spec enter_loop(atom(), libp2p_connection:connection(), [any()]) -> {stop, {error, term()}} |
                                                                     no_return().
enter_loop(Module, Connection, Args) ->
    case Module:init(Args) of
        {ok, State} ->
            case fdset(Connection) of
                ok ->
                    gen_server:enter_loop(?MODULE, [], mk_state(Connection, Module, State));
                {error, Error} ->
                    {stop, {error, Error}}
            end;
        {ok, Response, State} ->
            case send(Connection, Response) of
                {error, Error} -> {stop, {error, Error}};
                ok ->
                    case fdset(Connection) of
                        ok ->
                            gen_server:enter_loop(?MODULE, [], mk_state(Connection, Module, State));
                        {error, Error} ->
                            {stop, {error, Error}}
                    end
            end;
        {stop, Reason} -> {stop, Reason};
        {stop, Reason, Response} ->
            case send(Connection, Response) of
                {error, Error} -> {stop, {error, Error}};
                ok -> {stop, Reason}
            end
    end.

init(_) ->
    ignore.

handle_info({inert_read, _, _}, State=#state{connection=Connection, module=Module, state=ModuleState}) ->
    case recv(Connection, ?RECV_TIMEOUT) of
        {error, timeout} ->
            %% timeouts are fine and not an error we want to propogate because there's no waiter
            {noreply, State};
        {error, Error}  ->
            lager:debug("framed inert RECV ~p, ~p", [Error, Connection]),
            {stop, {error, Error}, State};
        {ok, Bin} -> handle_resp(Module:handle_data(Bin, ModuleState), State)
    end.

handle_resp({resp, Data, ModuleState}, State=#state{connection=Connection}) ->
    case send(Connection, Data) of
        {error, Error} -> {stop, {error, Error}, State};
        ok ->
            case fdset(Connection) of
                ok ->
                    {noreply, State#state{state=ModuleState}};
                {error, Error} ->
                    {stop, {error, Error}}
            end
    end;
handle_resp(noresp, State=#state{state=ModuleState}) ->
    handle_resp({noresp, ModuleState}, State);
handle_resp({noresp, ModuleState}, State=#state{connection=Connection}) ->
    case fdset(Connection) of
        ok ->
            {noreply, State#state{state=ModuleState}};
        {error, Error} ->
            {stop, {error, Error}}
    end;
handle_resp({stop, Reason, ModuleState}, State=#state{}) ->
    {stop, Reason, State#state{state=ModuleState}};

handle_resp(Msg, State=#state{}) ->
    lager:error("Unhandled framed stream response ~p", [Msg]),
    {stop, {error, bad_resp}, State}.


handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec fdset(libp2p_connection:connection()) -> ok | {error, term()}.
fdset(Connection) ->
    libp2p_connection:fdset(Connection).

-spec send(libp2p_connecton:connection(), binary() | list()) -> ok | {error, term()}.
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
            libp2p_connection:recv(Connection, Size, Timeout)
    end.
