-module(libp2p_peer_remove_gossip).
-behavior(libp2p_peer_gossip_handler).
%% API
-export([install_handler/1, init_gossip_data/1, handle_gossip_data/3]).

-define(GOSSIP_GROUP_KEY, "peer_remove").

-spec install_handler(ets:tid())-> ok | {error, any()}.
install_handler(TID)->
    libp2p_group_gossip:add_handler(self(),  ?GOSSIP_GROUP_KEY, {?MODULE, TID}),
    ok.

-spec init_gossip_data(ets:tab()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(_TID) ->
    ok.


-spec handle_gossip_data(pid(), [libp2p_crypto:pubkey_bin()], any()) -> noreply.
handle_gossip_data(_StreamPid, Data, Handle) ->
    lager:debug("~p got gossip data ~p",[Handle, Data]),
    Peerbook = libp2p_swarm:peerbook(Handle),
    ok = lists:foreach(fun(PeerId)-> libp2p_peerbook:remove(Peerbook, PeerId) end, Data),
    noreply.


