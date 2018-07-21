-module(libp2p_group_relcast).

-type opt() :: {stream_clients, [libp2p_group:stream_client_spec()]}.

-export_type([opt/0]).

-export([start_link/3, get_opt/3, handle_input/2, send_ack/2, info/1, queues/1]).

-spec start_link(ets:tab(), GroupID::string(), Args::[any()])
                -> {ok, pid()} | {error, term()}.
start_link(TID, GroupID, Args) ->
    libp2p_group_relcast_sup:start_link(TID, GroupID, Args).

-spec handle_input(GroupPid::pid(), Msg::binary()) -> ok.
handle_input(GroupPid, Msg) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    libp2p_group_relcast_server:handle_input(Server, Msg).

send_ack(GroupPid, Index) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    libp2p_group_relcast_server:send_ack(Server, Index).

-spec get_opt(libp2p_config:opts(), atom(), any()) -> any().
get_opt(Opts, Key, Default) ->
    libp2p_config:get_opt(Opts, [?MODULE, Key], Default).


%% @doc Gets information for a group. The information is represented
%% as a nested map of information related to the workers, sessions and
%% streams that build up the group.
-spec info(pid()) -> map().
info(GroupPid) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    gen_server:call(Server, info).

%% @doc Get the messages queued in the relcast server.
-spec queues(pid()) -> map().
queues(GroupPid) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    gen_server:call(Server, dump_queues).
