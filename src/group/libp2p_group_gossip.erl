-module(libp2p_group_gossip).

-type opt() :: {peerbook_connections, pos_integer()}
             | {drop_timeout, pos_integer()}
             | {stream_clients, [libp2p_group:stream_client_spec()]}
             | {seed_nodes, [MultiAddr::string()]}.

-export_type([opt/0]).

-export([group_agent_spec/2, get_opt/3]).

-spec group_agent_spec(term(), ets:tab()) -> supervisor:child_spec().
group_agent_spec(Id, TID) ->
    #{ id => Id,
       start => {libp2p_group_gossip_sup, start_link, [TID]},
       type => supervisor
     }.

-spec get_opt(libp2p_config:opts(), atom(), any()) -> any().
get_opt(Opts, Key, Default) ->
    libp2p_config:get_opt(Opts, [?MODULE, Key], Default).
