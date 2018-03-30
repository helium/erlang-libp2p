-module(libp2p_transport).

-type connection_handler() :: {atom(), atom()}.

-callback start_link(ets:tab()) -> {ok, pid()} | ignore | {error, term()}.
-callback start_listener(pid(), string()) -> {ok, [string()], pid()} | {error, term()} | {error, term()}.
-callback connect(pid(), string(), [libp2p_swarm:connect_opt()], pos_integer(), ets:tab()) -> {ok, libp2p_session:pid()} | {error, term()}.
-callback match_addr(string()) -> {ok, string()} | false.


-export_type([connection_handler/0]).
-export([for_addr/2, connect_to/4, start_client_session/3, start_server_session/3]).


-spec for_addr(ets:tab(), string()) -> {ok, string(), {atom(), pid()}} | {error, term()}.
for_addr(TID, Addr) ->
    lists:foldl(fun({Transport, Pid}, Acc={error, _}) ->
                        case Transport:match_addr(Addr) of
                            false -> Acc;
                            {ok, Matched} -> {ok, Matched, {Transport, Pid}}
                        end;
                   (_, Acc) -> Acc
                end, {error, {unsupported_address, Addr}}, libp2p_config:lookup_transports(TID)).

%% @doc Connect through a transport service. This is a convenience
%% function that verifies the given multiaddr, finds the right
%% transport, and checks if a session already exists for the given
%% multiaddr. The existing session is returned if it already exists,
%% or a `connect' call is made to transport service to perform the
%% actual connect.
-spec connect_to(string(), [libp2p_swarm:connect_opt()], pos_integer(), ets:tab())
                -> {ok, string(), libp2p_session:pid()} | {error, term()}.
connect_to(Addr, Options, Timeout, TID) ->
    case libp2p_transport:for_addr(TID, Addr) of
        {ok, ConnAddr, {Transport, TransportPid}} ->
            case libp2p_config:lookup_session(TID, ConnAddr, Options) of
                {ok, Pid} -> {ok, ConnAddr, Pid};
                false ->
                    lager:info("~p connecting to ~p", [Transport, ConnAddr]),
                    try Transport:connect(TransportPid, ConnAddr, Options, Timeout, TID) of
                        {error, Error} -> {error, Error};
                        {ok, SessionPid} -> {ok, ConnAddr, SessionPid}
                    catch
                        What:Why -> {error, {What, Why}}
                    end
            end;
        {error, Error} -> {error, Error}
    end.

%%
%% Session negotiation
%%

-spec start_client_session(ets:tab(), string(), libp2p_connection:connection())
                          -> {ok, libp2p_session:pid()} | {error, term()}.
start_client_session(TID, Addr, Connection) ->
    Handlers = libp2p_config:lookup_connection_handlers(TID),
    case libp2p_multistream_client:negotiate_handler(Handlers, Addr, Connection) of
        {error, Error} -> {error, Error};
        {ok, {_, {M, F}}} ->
            ChildSpec = #{ id => make_ref(),
                           start => {M, F, [Connection, [], TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            SessionSup = libp2p_swarm_session_sup:sup(TID),
            {ok, SessionPid} = supervisor:start_child(SessionSup, ChildSpec),
            libp2p_config:insert_session(TID, Addr, SessionPid),
            libp2p_identify:spawn_identify(TID, SessionPid, client),
            case libp2p_connection:controlling_process(Connection, SessionPid) of
                ok -> {ok, SessionPid};
                {error, Error} ->
                    libp2p_connection:close(Connection),
                    {error, Error}
            end
    end.


-spec start_server_session(reference(), ets:tab(), libp2p_connection:connection()) -> {ok, pid()}.
start_server_session(Ref, TID, Connection) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    case libp2p_config:lookup_session(TID, RemoteAddr) of
        {ok, _Pid} ->
            % This should really not happen since the remote address
            % should be unique for most transports (e.g. a different
            % port for tcp)
            error({already_connected, RemoteAddr});
        false ->
            Handlers = [{Key, Handler} ||
                           {Key, {Handler, _}} <- libp2p_config:lookup_connection_handlers(TID)],
            {ok, SessionPid} = libp2p_multistream_server:start_link(Ref, Connection, Handlers, TID),
            libp2p_config:insert_session(TID, RemoteAddr, SessionPid),
            %% Since servers accept outside of the swarm server,
            %% notify it of this new session
            libp2p_swarm:register_session(libp2p_swarm:swarm(TID), RemoteAddr, SessionPid),
            libp2p_identify:spawn_identify(TID, SessionPid, server),
            {ok, SessionPid}
    end.
