-module(libp2p_session).

-behavior(libp2p_info).

-type stream_handler() :: {atom(), atom(), [any()]}.

-export_type([stream_handler/0]).

-export([ping/1, open/1, close/1, close/3, close_state/1, goaway/1, streams/1, addr_info/2, identify/3]).

-export([dial/2, dial_framed_stream/4]).

%% libp2p_info
-export([info/1]).

-spec ping(pid()) -> {ok, pos_integer()} | {error, term()}.
ping(Pid) ->
    gen_server:call(Pid, ping, infinity).

-spec open(pid()) -> {ok, libp2p_connection:connection()} | {error, term()}.
open(Pid) ->
    gen_server:call(Pid, open).

-spec close(pid()) -> ok.
close(Pid) ->
    try close(Pid, normal, 5000) of
        Res -> Res
    catch
        exit:timeout ->
            %% pid is hung, just kill it
            exit(Pid, kill);
        exit:noproc ->
            ok
    end.

-spec close(pid(), term(), non_neg_integer() | infinity) -> ok.
close(Pid, Reason, Timeout) ->
    gen_server:stop(Pid, Reason, Timeout).

-spec close_state(pid()) -> libp2p_connection:close_state().
close_state(Pid) ->
    gen_server:call(Pid, close_state).

-spec goaway(pid()) -> ok.
goaway(Pid) ->
    gen_server:call(Pid, goaway).

-spec streams(pid()) -> [pid()].
streams(Pid) ->
    gen_server:call(Pid, streams).

-spec addr_info(ets:tab(), pid()) -> {string(), string()}.
addr_info(TID, Pid) ->
    case libp2p_config:lookup_session_addr_info(TID, Pid) of
        {ok, AddrInfo} -> AddrInfo;
        false -> {"noproc", "noproc"}
    end.

-spec identify(pid(), Handler::pid(), HandlerData::any()) -> ok.
identify(Pid, Handler, HandlerData) ->
    Pid ! {identify, Handler, HandlerData},
    ok.

%%
%% libp2p_info
%%
info(Pid) ->
    gen_server:call(Pid, info).

%%
%% Stream negotiation
%%

-spec dial(string(), pid()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Path, SessionPid) ->
    try libp2p_session:open(SessionPid) of
        {error, Error} -> {error, Error};
        {ok, Connection} ->
            Handlers = [{Path, undefined}],
            try libp2p_multistream_client:negotiate_handler(Handlers, Path, Connection) of
                {error, Error} ->
                    lager:debug("Failed to negotiate handler for ~p: ~p", [Connection, Error]),
                    {error, Error};
                server_switch ->
                    lager:warning("Simultaneous connection with ~p resulted from dial", [libp2p_connection:addr_info(Connection)]),
                    {error, simultaneous_connection};
                {ok, _} -> {ok, Connection}
            catch
                What:Why -> {error, {What, Why}}
            end
    catch
        What:Why -> {error, {What, Why}}
    end.


-spec dial_framed_stream(Path::string(), Session::pid(), Module::atom(), Args::[any()])
                        -> {ok, Stream::pid()} | {error, term()}.
dial_framed_stream(Path, SessionPid, Module, Args) ->
    case dial(Path, SessionPid) of
        {error, Error} -> {error, Error};
        {ok, Connection} -> Module:client(Connection, Args)
    end.
