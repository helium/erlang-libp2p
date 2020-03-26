-module(libp2p_peer_resolution).

-behavior(libp2p_group_gossip_handler).

-include("pb/libp2p_peer_resolution_pb.hrl").

%% libp2p_group_gossip_handler
-export([handle_gossip_data/3, init_gossip_data/1]).

-export([   is_rfc1918_allowed/1,
            resolve/3,
            install_handler/1,
            refresh/2,
            has_public_ip/1,
            has_private_ip/1,
            is_dialable/1
        ]).

%% Gossip group key to register and transmit with
-define(GOSSIP_GROUP_KEY, "peer_resolution").

-ifdef(TEST).
-define(DEFAULT_PEERBOOK_ALLOW_RFC1918, true).
-else.
-define(DEFAULT_PEERBOOK_ALLOW_RFC1918, false).
-endif.

-spec install_handler(any())-> ok | {error, any()}.
install_handler(Handle)->
    throttle:setup(?MODULE, 10, per_minute),
    libp2p_group_gossip:add_handler(self(),  ?GOSSIP_GROUP_KEY, {?MODULE, Handle}),
    ok.

-spec init_gossip_data(ets:tab()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(_TID) ->
    ok.

-spec refresh(ets:tab(), libp2p_crypto:pubkey_bin() | libp2p_peer:peer()) -> ok.
refresh(TID, ID) when is_binary(ID) ->
    ThisPeerID = libp2p_swarm:p2p_address(TID),
    case ThisPeerID == ID of
        true ->
            ok;
        false ->
            case libp2p_peerbook:get(libp2p_swarm:peerbook(TID), ID) of
                {error, _Error} ->
                    GossipGroup = libp2p_swarm:gossip_group(TID),
                    ?MODULE:resolve(GossipGroup, ID, 0),
                    ok;
                {ok, Peer} ->
                    refresh(TID, Peer)
            end
    end;
refresh(TID, Peer) ->
    TimeDiffMinutes = application:get_env(libp2p, similarity_time_diff_mins, 1),
    case libp2p_peer:network_id_allowable(Peer, libp2p_swarm:network_id(TID)) andalso
         libp2p_peer:is_stale(Peer, timer:minutes(TimeDiffMinutes)) of
        false ->
            ok;
        true ->
            GossipGroup = libp2p_swarm:gossip_group(TID),
            ?MODULE:resolve(GossipGroup, libp2p_peer:pubkey_bin(Peer), libp2p_peer:timestamp(Peer)),
            ok
    end.


%%
%% Gossip Group
%%

-spec handle_gossip_data(pid(), binary(), libp2p_peerbook:peerbook()) -> {reply, iodata()} | noreply.
handle_gossip_data(StreamPid, Data, Handle) ->
    case libp2p_peer_resolution_pb:decode_msg(Data, libp2p_peer_resolution_msg_pb) of
        #libp2p_peer_resolution_msg_pb{msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}}} ->
            case throttle:check(?MODULE, StreamPid) of
                {ok, _, _} ->
                    %% look up our peerbook for a newer record for this peer
                    case libp2p_peerbook:get(Handle, PK) of
                        {ok, Peer} ->
                            case libp2p_peer:timestamp(Peer) > Ts of
                                true ->
                                    lager:debug("ARP response for ~p Success", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
                                    {reply, libp2p_peer_resolution_pb:encode_msg(
                                              #libp2p_peer_resolution_msg_pb{msg = {response, Peer}})};
                                false ->
                                    lager:debug("ARP response for ~p Failed - stale", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
                                    %% peer is as stale or staler than what they have
                                    noreply
                            end;
                        _ ->
                            lager:debug("ARP response for ~p Failed - notfound", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
                            %% don't have this peer
                            noreply
                    end;
                {limit_exceeded, _, _} ->
                    noreply
            end;
        #libp2p_peer_resolution_msg_pb{msg = {response, #libp2p_signed_peer_pb{} = Peer}} ->
            lager:debug("ARP result for ~p", [libp2p_crypto:pubkey_bin_to_p2p(libp2p_peer:pubkey_bin(Peer))]),
            %% send this peer to the peerbook
            libp2p_peerbook:put(Handle, [Peer]),
            noreply
    end.

-spec resolve(pid(), libp2p_crypto:pubkey_bin(), non_neg_integer()) -> ok.
resolve(GossipGroup, PK, Ts) ->
    lager:debug("ARP request for ~p", [libp2p_crypto:pubkey_bin_to_p2p(PK)]),
    libp2p_group_gossip:send(GossipGroup, ?GOSSIP_GROUP_KEY,
                             libp2p_peer_resolution_pb:encode_msg(
                               #libp2p_peer_resolution_msg_pb{
                                  msg = {request, #libp2p_peer_request_pb{pubkey=PK, timestamp=Ts}}})),
    ok.

%% @doc Returns whether peers publishing RFC1918 addresses are allowed
is_rfc1918_allowed(TID) ->
    Opts = libp2p_swarm:opts(TID),
    libp2p_config:get_opt(Opts, [?MODULE, allow_rfc1918], ?DEFAULT_PEERBOOK_ALLOW_RFC1918).

%% @doc Returns whether the peer is listening on a public, externally
%% visible IP address.
has_public_ip(Peer) ->
    ListenAddresses = libp2p_peer:listen_addrs(Peer),
    lists:any(fun libp2p_transport_tcp:is_public/1, ListenAddresses).

%% @doc Returns whether the peer is publishing a RFC1918 address
has_private_ip(Peer) ->
    ListenAddresses = libp2p_peer:listen_addrs(Peer),
    not lists:all(fun libp2p_transport_tcp:is_public/1, ListenAddresses).


%% @doc Returns whether the peer is dialable. A peer is dialable if it
%% has a public IP address or it is reachable via a relay address.
is_dialable(Peer) ->
    ListenAddrs = libp2p_peer:listen_addrs(Peer),
    lists:any(fun(Addr) ->
                      libp2p_transport_tcp:is_public(Addr) orelse
                          libp2p_relay:is_p2p_circuit(Addr)
              end, ListenAddrs).