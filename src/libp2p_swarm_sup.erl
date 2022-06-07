-module(libp2p_swarm_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/1,
    sup/1, opts/1, name/1, pubkey_bin/1,
    register_server/1, server/1,
    register_gossip_group/1, gossip_group/1,
    register_peerbook/1, peerbook/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(SUP, swarm_sup).
-define(SERVER, swarm_server).
-define(GOSSIP_GROUP, swarm_gossip_group).
-define(PEERBOOK, swarm_peerbook).
-define(ADDRESS, swarm_address).
-define(NAME, swarm_name).
-define(OPTS, swarm_opts).

%%====================================================================
%% API functions
%%====================================================================
start_link(Args) ->
    supervisor:start_link(?MODULE, Args).

-spec sup(ets:tab()) -> pid().
sup(TID) ->
    ets:lookup_element(TID, ?SUP, 2).

register_server(TID) ->
    ets:insert(TID, {?SERVER, self()}).

-spec server(ets:tab() | pid()) -> pid().
server(Sup) when is_pid(Sup) ->
    Children = supervisor:which_children(Sup),
    {?SERVER, Pid, _, _} = lists:keyfind(?SERVER, 1, Children),
    Pid;
server(TID) ->
    ets:lookup_element(TID, ?SERVER, 2).

-spec pubkey_bin(ets:tab()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(TID) ->
    ets:lookup_element(TID, ?ADDRESS, 2).

-spec name(ets:tab()) -> atom().
name(TID) ->
    ets:lookup_element(TID, ?NAME, 2).

-spec opts(ets:tab()) -> libp2p_config:opts() | any().
opts(TID) ->
    case ets:lookup(TID, ?OPTS) of
        [{_, Opts}] -> Opts;
        [] -> []
    end.

-spec gossip_group(ets:tab()) -> pid().
gossip_group(TID) ->
    ets:lookup_element(TID, ?GOSSIP_GROUP, 2).

register_gossip_group(TID) ->
    ets:insert(TID, {?GOSSIP_GROUP, self()}).

register_peerbook(TID) ->
    ets:insert(TID, {?PEERBOOK, self()}).

-spec peerbook(ets:tab()) -> pid().
peerbook(TID) ->
    ets:lookup_element(TID, ?PEERBOOK, 2).


%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([Name, Opts]) ->
    inert:start(),
    TID = ets:new(Name, [public, ordered_set, named_table, {read_concurrency, true}]),
    ets:insert(TID, {?SUP, self()}),
    ets:insert(TID, {?NAME, Name}),
    ets:insert(TID, {?OPTS, Opts}),
    case proplists:get_value(force_network_id, Opts) of
        undefined -> true;
        NetworkID -> ets:insert(TID, {network_id, NetworkID})
    end,
    % Get or generate our keys
    {PubKey, SigFun, ECDHFun} = init_keys(Opts),
    ets:insert(TID, {?ADDRESS, libp2p_crypto:pubkey_to_bin(PubKey)}),
    GroupDeletePred = libp2p_config:get_opt(Opts, group_delete_predicate, fun(_) -> false end),

    SupFlags = {one_for_all, 3, 10},
    ChildSpecs = [
        {listeners,
            {libp2p_swarm_listener_sup, start_link, [TID]},
            permanent,
            10000,
            supervisor,
            [libp2p_swarm_listener_sup]
        },
        {sessions,
            {libp2p_swarm_session_sup, start_link, [TID]},
            permanent,
            10000,
            supervisor,
            [libp2p_swarm_session_sup]
        },
        {transports,
            {libp2p_swarm_transport_sup, start_link, [TID]},
            permanent,
            10000,
            supervisor,
            [libp2p_swarm_transport_sup]
        },
        {group_mgr,
            {libp2p_group_mgr , start_link, [TID, GroupDeletePred]},
            permanent,
            10000,
            worker,
            [libp2p_group_mgr]
        },
        {groups,
            {libp2p_swarm_group_sup, start_link, [TID]},
            permanent,
            10000,
            supervisor,
            [libp2p_swarm_group_sup]
        },
        {?SERVER,
            {libp2p_swarm_server, start_link, [TID, SigFun, ECDHFun]},
            permanent,
            10000,
            worker,
            [libp2p_swarm_server]
        },
        {?GOSSIP_GROUP,
            {libp2p_group_gossip_sup, start_link, [TID]},
            permanent,
            10000,
            supervisor,
            [libp2p_group_gossip_sup]
        },
        {?PEERBOOK,
            {libp2p_peerbook, start_link, [TID, SigFun]},
            permanent,
            10000,
            supervisor,
            [libp2p_peerbook]
        },
        {libp2p_swarm_auxiliary_sup,
            {libp2p_swarm_auxiliary_sup, start_link, [[TID, Opts]]},
            permanent,
            10000,
            supervisor,
            [libp2p_swarm_auxiliary_sup]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec init_keys(libp2p_swarm:swarm_opts()) -> {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun(), libp2p_crypto:ecdh_fun()}.
init_keys(Opts) ->
    case libp2p_config:get_opt(Opts, key, false) of
        false ->
            #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
            {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)};
        {PubKey, SigFun, ECDHFun} -> {PubKey, SigFun, ECDHFun}
    end.
