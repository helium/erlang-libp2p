-module(libp2p_group_relcast).

-type opt() :: {stream_clients, [libp2p_group_worker:stream_client_spec()]}.

-export_type([opt/0]).

-export([start_link/3, handle_input/2, send/2,
         status/1, info/1, queues/1, handle_command/2]).

-spec start_link(ets:tab(), GroupID::string(), Args::[any()])
                -> {ok, pid()} | {error, term()}.
start_link(TID, GroupID, Args) ->
    libp2p_group_relcast_sup:start_link(TID, GroupID, Args).

-spec handle_input(GroupPid::pid(), Msg::term()) -> ok.
handle_input(GroupPid, Msg) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    libp2p_group_relcast_server:handle_input(Server, Msg).

%% @doc Send the given data to the member of the group. The
%% implementation of the group determines the strategy used for
%% delivery. For gossip groups, for example, delivery is best effort.
-spec send(pid(), iodata()) -> ok | {error, term()}.
send(GroupPid, Data) ->
    gen_server:cast(GroupPid, {send, Data}).

%% @doc Gets information for a group. The information is represented
%% as a nested map of information related to the workers, sessions and
%% streams that build up the group.
-spec info(pid()) -> map().
info(GroupPid) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    gen_server:call(Server, info).

-spec status(pid()) -> atom().
status(GroupPid) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    gen_server:call(Server, status).

%% @doc Get the messages queued in the relcast server.
-spec queues(pid()) -> relcast:status().
queues(GroupPid) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    gen_server:call(Server, dump_queues).

-spec handle_command(GroupPid::pid(), Msg::term()) -> term() | {error, any()}.
handle_command(GroupPid, Msg) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    libp2p_group_relcast_server:handle_command(Server, Msg).
