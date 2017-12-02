-module(libp2p_multistream_server).

-behavior(gen_server).

-export([start_link/4, init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {
          connection :: libp2p_connection:connection(),
          handlers :: [{prefix(), handler()}],
          handler_opt :: any()
         }).

-type prefix() :: string().
-type handler() :: {atom(), atom()} | {atom(), atom(), any()}.

%%
%% gen_server
%%

-spec start_link(any(), libp2p_connection:connection(), [{string(), term()}], any()) -> {ok, pid()}.
start_link(Ref, Connection, Handlers, HandlerOpt) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Connection, Handlers, HandlerOpt}])}.

init({Ref, Connection, Handlers, HandlerOpt}) ->
    libp2p_connection:acknowledge(Connection, Ref),
    self() ! handshake,
    gen_server:enter_loop(?MODULE, [],
                          #state{connection=Connection, handlers=Handlers, handler_opt=HandlerOpt},
                          5000).

handle_info({inert_read, _, _}, State=#state{connection=Conn,
                                             handlers=Handlers,
                                             handler_opt=HandlerOpt}) ->
    case read(Conn) of
        "ls" ->
            handle_ls(Conn, Handlers),
            {noreply, fdset(Conn, State)};
        Line ->
            case find_handler(Line, Handlers) of
                {Key, {M, F}, LineRest} ->
                    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
                    write(Conn, Line),
                    lager:info("Negotiated server handler for ~p: ~p", [RemoteAddr, Key]),
                    erlang:apply(M, F, [Conn, LineRest, HandlerOpt, []]),
                    {stop, normal, State};
                {Key, {M, F, A}, LineRest} ->
                    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
                    write(Conn, Line),
                    lager:info("Negotiated server handler for ~p: ~p", [RemoteAddr, Key]),
                    erlang:apply(M, F, [Conn, LineRest, HandlerOpt, A]),
                    {stop, normal, State};
                error ->
                    write(Conn, "na"),
                    {noreply, fdset(Conn, State)}
            end
    end;
handle_info(handshake, State=#state{connection=Conn}) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
    lager:info("Starting handshake with client ~p", [RemoteAddr]),
    case handshake(Conn) of
        ok ->
            {noreply, fdset(Conn, State)};
        {error, Error} ->
            lager:error("Failed to handshake client ~p: ~p", [RemoteAddr, Error]),
            {stop, {error, Error}, State}
    end;
handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled message: ~p", [Msg]),
    {noreply, State}.

handle_call(_Request, _From, State) ->
        {reply, ok, State}.

handle_cast(_Msg, State) ->
        {noreply, State}.


terminate(_Reason, State=#state{connection=Connection}) ->
    fdclr(Connection, State).

%%
%% Internal
%%

fdset(Connection, State) ->
    case libp2p_connection:fdset(Connection) of
        ok -> ok;
        {error, Error} -> error(Error)
    end,
    State.

fdclr(Connection, State) ->
    libp2p_connection:fdclr(Connection),
    State.

handle_ls(Conn, Handlers) ->
    Keys = [Key || {Key, _} <- Handlers],
    case libp2p_multistream:write_lines(Conn, Keys) of
        ok -> ok;
        {error, Reason} -> error(Reason)
    end.

-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    write(Connection, Id),
    case read(Connection) of
        Id -> ok;
        ClientId -> {error, {protocol_mismatch, ClientId}}
    end.

-spec find_handler(string(), [{prefix(), handler()}]) -> {string(), handler(), string()} | error.
find_handler(_Line, []) ->
    error;
find_handler(Line, [{Prefix, Handler} | Handlers]) ->
    case string:prefix(Line, Prefix) of
        nomatch -> find_handler(Line, Handlers);
        Rest -> {Prefix, Handler, Rest}
    end.


write(Conn, Data) ->
    ok = libp2p_multistream:write(Conn, Data).

read(Conn) ->
    case libp2p_multistream:read(Conn) of
        {error, Reason} -> error(Reason);
        Data -> Data
    end.
