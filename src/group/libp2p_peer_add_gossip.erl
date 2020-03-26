-module(libp2p_peer_add_gossip).
-behavior(libp2p_peer_gossip_handler).
%% API
-export([install_handler/1, init_gossip_data/1, handle_gossip_data/3]).

-define(GOSSIP_GROUP_KEY, "peer_add").

-ifdef(TEST).
-define(GOSSIP_PEER_MIN_CONNS, 0).
-else.
-define(GOSSIP_PEER_MIN_CONNS, 5).
-endif.

-spec install_handler(ets:tid())-> ok | {error, any()}.
install_handler(TID)->
    libp2p_group_gossip:add_handler(self(),  ?GOSSIP_GROUP_KEY, {?MODULE, TID}),
    ok.

%% init_gossip_data1 & handle_gossip_data/2 used to be in peerbook
-spec init_gossip_data(ets:tab()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(TID) ->
    LocalAddr = libp2p_swarm:pubkey_bin(TID),
    Peerbook = libp2p_swarm:peerbook(TID),
    gossip_eligible_peer(Peerbook, LocalAddr).


-spec handle_gossip_data(pid(), binary(), any()) -> noreply.
handle_gossip_data(_StreamPid, Data, Handle) ->
    lager:debug("~p got gossip data ~p",[Handle, Data]),
    Peerbook = libp2p_swarm:peerbook(Handle),
    {ok, GossipedPeerList} = libp2p_peer:decode_list(Data),
    F = fun(Peer)->
            lager:debug("~p putting peer: ~p", [Handle, Peer]),
            case libp2p_peer_resolution:is_rfc1918_allowed(Handle) orelse
                    not libp2p_peer_resolution:has_private_ip(Peer) of
                true ->
                    libp2p_peerbook:put(Peerbook, Peer);
                false ->
                    lager:debug("not putting peer",[]),
                    ok
            end
        end,
    ok = lists:foreach(F, GossipedPeerList),
    noreply.

%%
%% Internal functions
%%
gossip_eligible_peer(Peerbook, LocalAddr)->
    gossip_eligible_peer(Peerbook, LocalAddr, 10).
gossip_eligible_peer(_Peerbook, _LocalAddr, 0)->
    lager:warning("failed to get random dialable peer", []),
    ok;
gossip_eligible_peer(Peerbook, LocalAddr, Attempts)->
    %% find a peer with a min of 5 connections
   case libp2p_peerbook:random(Peerbook, [LocalAddr], ?GOSSIP_PEER_MIN_CONNS) of
       {_Addr, Peer} ->
           %% ok we got a peer with our required min num of connections
           %% but check its dialable
            case libp2p_peer_resolution:is_dialable(Peer) of
                true->
                    Data = libp2p_peer:encode_list([Peer]),
                    {send, Data};
                false ->
                    gossip_eligible_peer(Peerbook, LocalAddr, Attempts - 1)
            end;
       _ ->
           gossip_eligible_peer(Peerbook, LocalAddr, Attempts - 1)
     end.


