-module(libp2p_group).

-type stream_client_spec() :: {Path::string(), {Module::atom(), Args::[any()]}}.

-export_type([stream_client_spec/0]).

% API
-export([sessions/1, send/2]).

%% @doc Get the active list of sessions and their associated
%% multiaddress.
-spec sessions(pid()) -> [{string(), pid()}].
sessions(Pid) ->
    gen_server:call(Pid, sessions).

%% @doc Send the given data to the member of the group. The
%% implementation of the group determines the strategy used for
%% delivery. For gossip groups, for example, delivery is best effort.
-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Pid, Data) ->
    gen_server:cast(Pid, {send, Data}).
