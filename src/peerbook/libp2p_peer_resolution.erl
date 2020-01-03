-module(libp2p_peer_resolution).

-behavior(libp2p_group_gossip_handler).

-include("pb/libp2p_peer_resolution_pb.hrl").

%% libp2p_group_gossip_handler
-export([handle_gossip_data/2, init_gossip_data/1]).

-export([resolve/3, install_handler/2]).

%% Gossip group key to register and transmit with
-define(GOSSIP_GROUP_KEY, "peer_resolution").

-spec resolve(pid(), libp2p_crypto:pubkey_bin(), non_neg_integer()) -> ok.
resolve(GossipGroup, PK, Ts) ->
    libp2p_group_gossip:send(GossipGroup, ?GOSSIP_GROUP_KEY, 
                             libp2p_peer_resolution_pb:encode_msg(
                               #libp2p_peer_resolution_msg_pb{
                                  msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}}})),
    ok.

install_handler(G, Handle) ->
    libp2p_group_gossip:add_handler(G,  ?GOSSIP_GROUP_KEY, {?MODULE, Handle}),
    ok.

%%
%% Gossip Group
%%

-spec handle_gossip_data(binary(), libp2p_peerbook:peerbook()) -> {reply, iodata()} | noreply.
handle_gossip_data(Data, Handle) ->
    case libp2p_peer_resolution_pb:decode_msg(Data, libp2p_peer_resolution_msg_pb) of
        #libp2p_peer_resolution_msg_pb{msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}}} ->
            %% look up our peerbook for a newer record for this peer
            case libp2p_peerbook:get(Handle, PK) of
                {ok, Peer} ->
                    case libp2p_peer:timestamp(Peer) > Ts of
                        true ->
                            lager:notice("ARP response for ~p Success", [PK]),
                            {reply, libp2p_peer_resolution_pb:encode_msg(
                                      #libp2p_peer_resolution_msg_pb{msg = {response, Peer}})};
                        false ->
                            lager:notice("ARP response for ~p Failed - stale", [PK]),
                            %% peer is as stale or staler than what they have
                            noreply
                    end;
                _ ->
                    lager:notice("ARP response for ~p Failed - notfound", [PK]),
                    %% don't have this peer
                    noreply
            end;
        #libp2p_peer_resolution_msg_pb{msg = {response, #libp2p_signed_peer_pb{} = Peer}} ->
            lager:notice("ARP request for ~p", [libp2p_peer:pubkey_bin(Peer)]),
            %% send this peer to the peerbook
            libp2p_peerbook:put(Handle, [Peer]),
            noreply
    end.



-spec init_gossip_data(libp2p_peerbook:peerbook()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(_Peerbook) ->
    %% nothing to send on init
    ok.
