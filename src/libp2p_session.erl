-module(libp2p_session).

-type stream_handler() :: {atom(), atom(), [any()]}.

-export_type([stream_handler/0]).

-export([ping/1, open/1, close/1, close_state/1, goaway/1, streams/1, addr_info/1]).

-export([start_client_stream/3]).

-spec ping(pid()) -> {ok, pos_integer()} | {error, term()}.
ping(Pid) ->
    gen_server:call(Pid, ping, infinity).

-spec open(pid()) -> {ok, libp2p_connection:connection()} | {error, term()}.
open(Pid) ->
    gen_server:call(Pid, open).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:stop(Pid).

-spec close_state(pid()) -> libp2p_connection:close_state().
close_state(Pid) ->
    gen_server:call(Pid, close_state).

-spec goaway(pid()) -> ok.
goaway(Pid) ->
    gen_server:call(Pid, goaway).

-spec streams(pid()) -> [pid()].
streams(Pid) ->
    gen_server:call(Pid, streams).

-spec addr_info(pid()) -> {string(), string()}.
addr_info(Pid) ->
    gen_server:call(Pid, addr_info).


%%
%% Stream negotiation
%%

-spec start_client_stream(ets:tab(), string(), libp2p_session:pid())
                         -> {ok, libp2p_connection:connection()} | {error, term()}.
start_client_stream(_TID, Path, SessionPid) ->
    try libp2p_session:open(SessionPid) of
        {error, Error} -> {error, Error};
        {ok, Connection} ->
            Handlers = [{Path, undefined}],
            try libp2p_multistream_client:negotiate_handler(Handlers, "stream", Connection) of
                {error, Error} -> {error, Error};
                {ok, _} -> {ok, Connection}
            catch
                What:Why -> {error, {What, Why}}
            end
    catch
        What:Why -> {error, {What, Why}}
    end.
