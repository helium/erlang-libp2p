-module(libp2p_transport).

-type connection_handler() :: {atom(), atom()}.

-export_type([connection_handler/0]).
-export([for_addr/2, start_client_session/3]).


-spec for_addr(ets:tab(), string()) -> {ok, string(), {atom(), pid()}} | {error, term()}.
for_addr(TID, Addr) ->
    lists:foldl(fun({Transport, Pid}, Acc={error, _}) ->
                        case Transport:match_addr(Addr) of
                            false -> Acc;
                            {ok, Matched} -> {ok, Matched, {Transport, Pid}}
                        end;
                   (_, Acc) -> Acc
                end, {error, {unsupported_address, Addr}}, libp2p_config:lookup_transports(TID)).


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
            case libp2p_connection:controlling_process(Connection, SessionPid) of
                ok -> {ok, SessionPid};
                {error, Error} ->
                    libp2p_connection:close(Connection),
                    {error, Error}
            end
    end.
