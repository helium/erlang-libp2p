-module(libp2p_group_relcast).

-type opt() :: {stream_clients, [libp2p_group:stream_client_spec()]}.

-export_type([opt/0]).

-export([start_link/3, get_opt/3, handle_input/2]).

-spec get_opt(libp2p_config:opts(), atom(), any()) -> any().
get_opt(Opts, Key, Default) ->
    libp2p_config:get_opt(Opts, [?MODULE, Key], Default).

-spec start_link(Swarm::pid(), HandlerModule::atom(), HandlerArgs::[any()]) -> {ok, pid()} | {error, term()}.
start_link(Swarm, Handler, Args) ->
    libp2p_group_relcast_sup:start_link(libp2p_swarm:tid(Swarm), Handler, Args).

-spec handle_input(pid(), Msg::binary()) -> ok.
handle_input(GroupPid, Msg) ->
    Server = libp2p_group_relcast_sup:server(GroupPid),
    libp2p_group_relcast_server:handle_input(Server, Msg).
