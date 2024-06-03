-module(libp2p_peer_resolution).

-behavior(libp2p_group_gossip_handler).

-include("pb/libp2p_peer_resolution_pb.hrl").

%% libp2p_group_gossip_handler
-export([handle_gossip_data/5, init_gossip_data/1]).

-export([resolve/3, install_handler/2]).

%% Gossip group key to register and transmit with
-define(GOSSIP_GROUP_KEY, "peer_resolution").

-spec resolve(ets:tab(), libp2p_crypto:pubkey_bin(), non_neg_integer()) -> ok.
resolve(TID, PK, Ts) ->
    lager:debug("ARP request for ~p", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
    libp2p_group_gossip:send(TID, ?GOSSIP_GROUP_KEY,
                             enif_protobuf:encode(
                               #libp2p_peer_resolution_msg_pb{
                                  msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}}})),
    ok.

re_resolve(TID, PK, Ts) ->
    libp2p_group_gossip:send(TID, seed, ?GOSSIP_GROUP_KEY,
                             enif_protobuf:encode(
                               #libp2p_peer_resolution_msg_pb{
                                  msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}},
                                  re_request = true})),
    ok.


install_handler(G, Handle) ->
    load_pb_msg_defs(),
    Limit = application:get_env(libp2p, arp_limit, 10),
    throttle:setup(?MODULE, Limit, per_minute),
    prometheus:start(),
    prometheus_gauge:declare([{name, arp}, {help, "Inbound ARP requests"}]),
    prometheus_gauge:declare([{name, arp_rerequests}, {help, "Inbound ARP rerequests"}]),
    prometheus_gauge:declare([{name, arp_dropped}, {help, "Rejected ARP requests"}]),
    prometheus_gauge:declare([{name, arp_responses}, {help, "ARP responses sent"}]),
    prometheus_gauge:declare([{name, arp_results}, {help, "ARP result received"}]),
    libp2p_group_gossip:add_handler(G,  ?GOSSIP_GROUP_KEY, {?MODULE, Handle}),
    ok.

%%
%% Gossip Group
%%

-spec handle_gossip_data(pid(), seed | inbound | peerbook, string(), {string(), binary()}, libp2p_peerbook:peerbook()) -> {reply, iodata()} | noreply.
handle_gossip_data(_StreamPid, _Kind, undefined, {_Path, _Data}, _Handle) ->
    noreply;
handle_gossip_data(_StreamPid, Kind, GossipPeer, {_Path, Data}, Handle) ->
    %% check this peer is actually legitimately connected to us so
    %% we don't poison the throttle
    case is_valid_peer(Kind, GossipPeer, Handle) of
        true ->
            case enif_protobuf:decode(Data, libp2p_peer_resolution_msg_pb) of
                #libp2p_peer_resolution_msg_pb{msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}}, re_request=ReRequest} ->
                    case throttle_check(GossipPeer, ReRequest) of
                        {ok, _, _} ->
                            case ReRequest of
                                true ->
                                    prometheus_gauge:inc(arp_rerequests);
                                _ ->
                                    prometheus_gauge:inc(arp)
                            end,
                            %% look up our peerbook for a newer record for this peer
                            case libp2p_peerbook:get(Handle, PK) of
                                {ok, Peer} ->
                                    case libp2p_peer:timestamp(Peer) > Ts andalso libp2p_peer:listen_addrs(Peer) /= [] of
                                        true ->
                                            lager:debug("ARP response for ~p Success", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
                                            prometheus_gauge:inc(arp_responses),
                                            {reply, enif_protobuf:encode(
                                                      #libp2p_peer_resolution_msg_pb{msg = {response, Peer}})};
                                        false ->
                                            maybe_re_resolve(Handle, ReRequest, PK, Ts),
                                            lager:debug("ARP response for ~p Failed - stale", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
                                            %% peer is as stale or staler than what they have
                                            noreply
                                    end;
                                _ ->
                                    lager:debug("ARP response for ~p Failed - notfound", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
                                    maybe_re_resolve(Handle, ReRequest, PK, Ts),
                                    %% don't have this peer
                                    noreply
                            end;
                        {limit_exceeded, _, _} ->
                            prometheus_gauge:inc(arp_dropped),
                            noreply
                    end;
                #libp2p_peer_resolution_msg_pb{msg = {response, #libp2p_signed_peer_pb{} = Peer}, re_request=ReRequest} ->
                    lager:debug("ARP result for ~p", [libp2p_crypto:pubkey_bin_to_p2p(libp2p_peer:pubkey_bin(Peer))]),
                    prometheus_gauge:inc(arp_results),
                    %% send this peer to the peerbook
                    Res = libp2p_peerbook:put(Handle, [Peer]),
                    %% refresh any relays this peer is using as well so we don't fail
                    %% a subsequent dial
                    case ReRequest of
                        true ->
                            %% don't spider the relay addresses
                            %% since this is a seed node
                            ok;
                        false ->
                            lists:foreach(fun(Address) ->
                                                  case libp2p_relay:p2p_circuit(Address) of
                                                      {ok, {Relay, _PeerAddr}} ->
                                                          libp2p_peerbook:refresh(Handle, libp2p_crypto:p2p_to_pubkey_bin(Relay));
                                                      error ->
                                                          ok
                                                  end
                                          end, libp2p_peer:listen_addrs(Peer))
                    end,
                    case Res == ok andalso ReRequest andalso application:get_env(libp2p, seed_node, false) of
                        true ->
                            %% this was a re-request, so gossip this update to everyone else too
                            GossipGroup = libp2p_peerbook:tid(Handle),
                            libp2p_group_gossip:send(GossipGroup, ?GOSSIP_GROUP_KEY,
                                                     enif_protobuf:encode(
                                                       #libp2p_peer_resolution_msg_pb{msg = {response, Peer}, re_request=ReRequest})),
                            noreply;
                        false ->
                            noreply
                    end
            end;
        _ ->
            noreply
    end.

is_valid_peer(seed, _, _) ->
    true;
is_valid_peer(_, Peer, Handle) ->
    case libp2p_peerbook:get(Handle, libp2p_crypto:p2p_to_pubkey_bin(Peer)) of
        {ok, _} ->
            true;
        _ ->
            false
    end.

maybe_re_resolve(Peerbook, ReRequest, PK, Ts) ->
    case ReRequest /= true andalso application:get_env(libp2p, seed_node, false) of
        true ->
            %% only have seed nodes re-request, and only from other seed nodes and
            %% only if this is not a re-request itself
            TID = libp2p_peerbook:tid(Peerbook),
            lager:debug("ARP re-request for ~p", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
            re_resolve(TID, PK, Ts);
        false ->
            ok
    end.

-spec init_gossip_data(libp2p_peerbook:peerbook()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(_Peerbook) ->
    %% nothing to send on init
    ok.

throttle_check(GossipPeer, true) ->
    %% allow 10x more arp requests between seed nodes than from any single normal peer
    throttle:check(?MODULE, {rand:uniform(10), GossipPeer});
throttle_check(GossipPeer, false) ->
    throttle:check(?MODULE, GossipPeer).

load_pb_msg_defs() ->
    ok = enif_protobuf:load_cache(libp2p_peer_resolution_pb:get_proto_defs()),
    enif_protobuf:set_opts([{string_as_list, true}]).
