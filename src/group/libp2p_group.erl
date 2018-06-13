-module(libp2p_group).

-type stream_client_spec() :: {Path::string(), {Module::atom(), Args::[any()]}}.

-export_type([stream_client_spec/0]).

% API
-export([workers/1, send/2]).

%% @doc Get the active list of group workers and their associated
%% multiaddress.
-spec workers(pid()) -> [{string(), pid()}].
workers(Pid) ->
    gen_server:call(Pid, workers).

%% @doc Send the given data to the member of the group. The
%% implementation of the group determines the strategy used for
%% delivery. For gossip groups, for example, delivery is best effort.
-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Pid, Data) ->
    gen_server:cast(Pid, {send, Data}).
