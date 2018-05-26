-module(libp2p_session).

-type stream_handler() :: {atom(), atom(), [any()]}.

-export_type([stream_handler/0]).

-export([ping/1, open/1, close/1, close/3, close_state/1, goaway/1, streams/1, addr_info/1]).

-export([dial/2, dial_framed_stream/4, dial_framed_connection/4]).

-spec ping(pid()) -> {ok, pos_integer()} | {error, term()}.
ping(Pid) ->
    gen_server:call(Pid, ping, infinity).

-spec open(pid()) -> {ok, libp2p_connection:connection()} | {error, term()}.
open(Pid) ->
    gen_server:call(Pid, open).

-spec close(pid()) -> ok.
close(Pid) ->
    close(Pid, normal, infinity).

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

-spec addr_info(pid()) -> {string(), string()}.
addr_info(Pid) ->
    gen_server:call(Pid, addr_info).


%%
%% Stream negotiation
%%

-spec dial(string(), pid()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(Path, SessionPid) ->
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


-spec dial_framed_stream(Path::string(), Session::pid(), Module::atom(), Args::[any()]) ->
                                {ok, Stream::pid()} | {error, term()} | ignore.
dial_framed_stream(Path, SessionPid, Module, Args) ->
    case dial(Path, SessionPid) of
        {error, Error} -> {error, Error};
        {ok, Connection} -> Module:client(Connection, Args)
    end.

-spec dial_framed_connection(Path::string(), Session::pid(), Module::atom(), Args::[any()]) ->
                                    {ok, libp2p_connection:connection()} | {error, term()} | ignore.
dial_framed_connection(Path, SessionPid, Module, Args) ->
    case dial_framed_stream(Path, SessionPid, Module, Args) of
        {ok, Stream} -> {ok, libp2p_framed_stream:new_connection(Stream)};
        Other -> Other
    end.
