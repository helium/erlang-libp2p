-module(libp2p_multistream_server).

-behavior(libp2p_connection_protocol).
-behavior(gen_server).

-export([start_link/3, init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

-define(TIMEOUT, 5000).

-record(state, {
          connection :: libp2p_connection:connection(),
          handlers=#{} :: maps:map()
         }).

%%
%% libp2p_connection_protocol
%%

start_link(Ref, Connection, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Connection, Opts}])}.

%%
%% gen_server
%%

init({Ref, Connection, _Opts}) ->
    libp2p_connection:acknowledge(Connection, Ref),
    self() ! handshake,
    inert:start(),
    gen_server:enter_loop(?MODULE, [], #state{connection=Connection}, ?TIMEOUT).

handle_info({inert_read, _, _}, State=#state{connection=Conn, handlers=Handlers}) ->
    io:format("GOT READ"),
    case read(Conn) of
        "ls" ->
            handle_ls(Conn, Handlers),
            fdset(Conn),
            {noreply, State};
        Line ->
            case maps:find(Line, Handlers) of
                {ok, {M, F, A}} ->
                    M:F(Conn, A),
                    {stop, normal, State};
                error ->
                    write(Conn, "na"),
                    fdset(Conn),
                    {noreply, State}
            end
    end;
handle_info(handshake, State=#state{connection=Connection}) ->
    handshake(Connection),
    fdset(Connection),
    {noreply, State};
handle_info(timeout, State) ->
    {stop, normal, State};
handle_info(Msg, State) ->
    io:format("UNHANDLED: ~p~n", [Msg]),
    {stop, normal, State}.

handle_call(_Request, _From, State) ->
        {reply, ok, State}.

handle_cast(_Msg, State) ->
        {noreply, State}.

terminate(_Reason, #state{connection=Connection}) ->
    libp2p_connection:close(Connection).

%%
%% Internal
%%

fdset(Connection) ->
    inert:fdset(libp2p_connection:getfd(Connection)).

handle_ls(Conn, Handlers) ->
    case libp2p_multistream:write_lines(Conn, maps:keys(Handlers)) of
        ok -> ok;
        {error, Reason} -> exit({error, Reason})
    end.

-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    write(Connection, Id),
    case read(Connection) of
        Id -> ok;
        ClientId -> exit({error, {protocol_mismatch, ClientId}})
    end.

write(Conn, Data) ->
    case libp2p_multistream:write(Conn, Data) of
        ok -> ok;
        {error, Reason} -> exit({error, Reason})
    end.

read(Conn) ->
    case libp2p_multistream:read(Conn) of
        {error, Reason} -> exit({error, Reason});
        Data -> Data
    end.
