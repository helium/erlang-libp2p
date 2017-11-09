-module(libp2p_swarm).
-compile([export_all]).


-record(swarm, {
          peer_info :: libp2p_peer:info()
         }).

new(PeerInfo) ->
    #swarm{peer_info=PeerInfo}.


dial(_Peer, _Protocol) ->
    undefined.
