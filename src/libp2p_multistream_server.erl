-module(libp2p_multistream_server).

-export([start_link/4, start_link/3, init/1]).

-record(state, {
          connection :: libp2p_connection:connection(),
          handlers :: [{prefix(), handler()}],
          handler_opt :: any()
         }).

-type prefix() :: string().
-type handler() :: {atom(), atom()} | {atom(), atom(), any()}.

%%
%% Note that this is NOT a gen_server, it is just a small shim to exec into some other main loop
%%

-spec start_link(any(), libp2p_connection:connection(), [{string(), term()}], any()) -> {ok, pid()}.
start_link(Ref, Connection, Handlers, HandlerOpt) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Connection, Handlers, HandlerOpt}])}.

-spec start_link(libp2p_connection:connection(), [{string(), term()}], any()) -> {ok, pid()}.
start_link(Connection, Handlers, HandlerOpt) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Connection, Handlers, HandlerOpt}])}.

init({Ref, Connection, Handlers, HandlerOpt}) ->
    ok = libp2p_connection:acknowledge(Connection, Ref),
    self() ! handshake,
    loop(#state{connection=Connection, handlers=Handlers, handler_opt=HandlerOpt});
init({Connection, Handlers, HandlerOpt}) ->
    ok = libp2p_connection:fdset(Connection),
    loop(#state{connection=Connection, handlers=Handlers, handler_opt=HandlerOpt}).


loop(State) ->
    %% XXX to avoid accidentally consuming messages destined for the actual session, once negotiated
    %% only do a selective receive here.
    receive
        {inert_read, _, _} = Msg ->
            handle_msg(Msg, State);
        handshake = Msg ->
            handle_msg(Msg, State);
        timeout = Msg ->
            handle_msg(Msg, State)
    after
        5000 ->
             ok
    end.

handle_msg(Msg, State) ->
    lager:info("handle msg ~p", [Msg]),
    case handle_info(Msg, State) of
        {noreply, NewState} ->
            loop(NewState);
        {exec, M, F, A} ->
            try erlang:apply(M, F, A) of
                Result -> Result
            catch
                What:Why -> terminate({What, Why}, State)
            end;
        {stop, Reason, NewState} ->
            terminate(Reason, NewState)
    end.

handle_info({inert_read, _, _}, State=#state{connection=Conn,
                                             handlers=Handlers,
                                             handler_opt=HandlerOpt}) ->
    case libp2p_multistream:read(Conn) of
        {error, timeout} ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, {error, Reason}, State};
        "ls" ->
            handle_ls_reply(Conn, Handlers, State);
        Line ->
            case find_handler(Line, Handlers) of
                {Key, {M, F}, LineRest} ->
                    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
                    write(Conn, Line),
                    lager:info("Negotiated server handler for ~p: ~p", [RemoteAddr, Key]),
                    {exec, M, F, [Conn, LineRest, HandlerOpt, []]};
                {Key, {M, F, A}, LineRest} ->
                    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
                    write(Conn, Line),
                    lager:info("Negotiated server handler for ~p: ~p", [RemoteAddr, Key]),
                    {exec, M, F, [Conn, LineRest, HandlerOpt, A]};
                error ->
                    lager:info("Can't find handler for ~p", [Line]),
                    write(Conn, "na"),
                    fdset_return(Conn, State)
            end
    end;
handle_info(handshake, State=#state{connection=Conn}) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
    case handshake(Conn) of
        ok ->
            fdset_return(Conn, State);
        {error, timeout} ->
            lager:notice("Timeout handshaking client ~p", [RemoteAddr]),
            {stop, normal, State};
        {error, Error} ->
            lager:notice("Failed to handshake client ~p: ~p", [RemoteAddr, Error]),
            {stop, {error, Error}, State}
    end;
handle_info(timeout, State) ->
    {stop, normal, State}.


terminate(_Reason, State=#state{connection=Connection}) ->
    fdclr(Connection, State),
    libp2p_connection:close(Connection).

%%
%% Internal
%%

fdset_return(Connection, State) ->
    case libp2p_connection:fdset(Connection) of
        ok -> {noreply, State};
        {error, Error} -> {stop, {error, Error}, State}
    end.

fdclr(Connection, State) ->
    libp2p_connection:fdclr(Connection),
    State.

handle_ls_reply(Conn, Handlers, State) ->
    Keys = [Key || {Key, _} <- Handlers],
    try libp2p_multistream:write_lines(Conn, Keys) of
        ok -> fdset_return(Conn, State);
        {error, timeout} -> {stop, normal, State};
        {error, Reason} -> {stop, {error, Reason}, State}
    catch
        What:Why -> {stop, {What, Why}, State}
    end.

-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    write(Connection, Id),
    case libp2p_multistream:read(Connection) of
        {error, Reason} -> {error, Reason};
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
    libp2p_multistream:write(Conn, Data).
