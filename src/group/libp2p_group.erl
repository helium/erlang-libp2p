-module(libp2p_group).

-type stream_client_spec() :: {Path::string(), {Module::atom(), Args::[any()]}}.

-export_type([stream_client_spec/0]).

% API
-export([sessions/1, send/2]).

-spec sessions(pid()) -> [{libp2p_crypto:address(), libp2p_session:pid()}].
sessions(Pid) ->
    gen_server:call(Pid, sessions).


-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Pid, Data) ->
    gen_server:cast(Pid, {send, Data}).
