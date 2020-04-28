-module(libp2p_peerbook).

-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).
-export([keys/1, values/1,
         put/2, put/3, get/2,
         random/1, random/2, random/3, random/4,
         refresh/2, is_key/2, remove/2, stale_time/1,
         join_notify/2, changed_listener/1, update_nat_type/2,
         register_session/3, unregister_session/2,
         blacklist_listen_addr/3,
         add_association/3, lookup_association/3]).
%% libp2p_group_gossip_handler
-export([handle_gossip_data/3, init_gossip_data/1]).

-type opt() :: {stale_time, pos_integer()}
             | {peer_time, pos_integer()}.

-export_type([opt/0]).

-behviour(gen_server).
-behavior(libp2p_group_gossip_handler).

-record(peerbook, { tid :: ets:tab(),
                    store :: rocksdb:db_handle(),
                    stale_time :: pos_integer()
                  }).
-type peerbook() :: #peerbook{}.

-export_type([peerbook/0]).

-record(state,
        { peerbook :: peerbook(),
          tid :: ets:tab(),
          nat_type = unknown :: libp2p_peer:nat_type(),
          peer_time :: pos_integer(),
          peer_timer :: undefined | reference(),
          gossip_peers_timer=make_ref() :: reference(),
          gossip_peers_timeout :: pos_integer(),
          gossip_group :: undefined | pid(),
          notify_group :: atom(),
          notify_time :: pos_integer(),
          notify_timer=undefined :: reference() | undefined,
          notify_peers=#{} :: #{libp2p_crypto:pubkey_bin() => libp2p_peer:peer()},
          sessions=#{} :: #{libp2p_crypto:pubkey_bin() => pid()},
          sigfun :: fun((binary()) -> binary()),
          metadata_fun :: fun(() -> map()),
          metadata = #{} :: map(),
          metadata_ref :: undefined | reference()
        }).

%% Default peer stale time is 24 hours (in milliseconds)
-define(DEFAULT_STALE_TIME, 24 * 60 * 60 * 1000).
%% Defailt "this" peer heartbeat time 5 minutes (in milliseconds)
-define(DEFAULT_PEER_TIME, 5 * 60 * 1000).
%% Default timer for new peer notifications to connected peers. This
%% allows for fast arrivels to coalesce a number of new peers before a
%% new list is sent out.
-define(DEFAULT_NOTIFY_TIME, 5 * 1000).
%% Gossip group key to register and transmit with
-define(GOSSIP_GROUP_KEY, "peer").
%% number of recently updated peerbook entries we should regossip to our
%% gossip peers
-define(DEFAULT_NOTIFY_PEER_GOSSIP_LIMIT, 100).
%% Default timeout for selecting eligible gossip peers. Set to 30
%% minutes (in milliseconds)
-define(DEFAULT_GOSSIP_PEERS_TIMEOUT, 30 * 60 * 1000).

-ifdef(TEST).
-define(DEFAULT_PEERBOOK_ALLOW_RFC1918, true).
-else.
-define(DEFAULT_PEERBOOK_ALLOW_RFC1918, false).
-endif.

%%
%% API
%%

-spec put(peerbook(), [libp2p_peer:peer()]) -> ok | {error, term()}.
put(Handle, PeerList) ->
    put(Handle, PeerList, false).

-spec put(peerbook(), [libp2p_peer:peer()], boolean()) -> ok | {error, term()}.
put(#peerbook{tid=TID, stale_time=StaleTime}=Handle, PeerList0, Prevalidated) ->
    PeerList =
        %% allow prevalidation so we can move the work around if needed
        case Prevalidated of
            true -> PeerList0;
            false -> lists:filter(fun libp2p_peer:verify/1, PeerList0)
        end,
    ThisPeerId = libp2p_swarm:pubkey_bin(TID),
    AllowRFC1918 = is_rfc1918_allowed(TID),
    NewPeers = lists:foldl(
                 fun(NewPeer, Acc) ->
                         NewPeerId = libp2p_peer:pubkey_bin(NewPeer),
                         case unsafe_fetch_peer(NewPeerId, Handle) of
                             {error, not_found} ->
                                 case AllowRFC1918 orelse not libp2p_peer:has_private_ip(NewPeer) of
                                     true ->
                                         store_peer(NewPeer, Handle),
                                         [NewPeer | Acc];
                                     false -> Acc
                                 end;
                             {ok, ExistingPeer} ->
                                 %% Only store peers that are not _this_ peer,
                                 %% are newer than what we have,
                                 %% are not stale themselves
                                 case NewPeerId /= ThisPeerId
                                     andalso (AllowRFC1918 orelse not libp2p_peer:has_private_ip(NewPeer))
                                     andalso libp2p_peer:supersedes(NewPeer, ExistingPeer)
                                     andalso not libp2p_peer:is_stale(NewPeer, StaleTime)
                                     andalso libp2p_peer:network_id_allowable(NewPeer, libp2p_swarm:network_id(TID)) of
                                     true ->
                                         %% even if the peer is similar, we should still
                                         %% store it because it's newer
                                         store_peer(NewPeer, Handle),
                                         case libp2p_peer:is_similar(NewPeer, ExistingPeer) of
                                             false ->
                                                 [NewPeer | Acc];
                                             true ->
                                                 Acc
                                         end;
                                     _ ->
                                         Acc
                                 end
                         end
                 end, [], PeerList),

    % Notify group of new peers
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), {notify_new_peers, NewPeers}),
    ok.

-spec get(peerbook(), libp2p_crypto:pubkey_bin()) -> {ok, libp2p_peer:peer()} | {error, term()}.
get(#peerbook{tid=TID}=Handle, ID) ->
    ThisPeerId = libp2p_swarm:pubkey_bin(TID),
    SeedNode = application:get_env(libp2p, seed_node, false),
    case fetch_peer(ID, Handle) of
        {error, not_found} when ID == ThisPeerId, SeedNode == false ->
            gen_server:call(libp2p_swarm:peerbook_pid(TID), update_this_peer, infinity),
            get(Handle, ID);
        {error, Error} ->
            {error, Error};
        {ok, Peer} ->
            case libp2p_peer:network_id_allowable(Peer, libp2p_swarm:network_id(TID)) of
               false ->
                    {error, not_found};
                true ->
                    {ok, Peer}
            end
    end.

random(Peerbook) ->
    random(Peerbook, [], fun(_Peer) -> true end, 15).

random(Peerbook, Exclude) ->
    random(Peerbook, Exclude, fun(_Peer) -> true end, 15).

random(Peerbook, Exclude, Pred) ->
    random(Peerbook, Exclude, Pred, 15).

random(Peerbook=#peerbook{store=Store, stale_time=StaleTime}, Exclude, Pred, Tries) ->
    {ok, Iterator} = rocksdb:iterator(Store, []),
    {ok, FirstAddr = <<Start:(33*8)/integer-unsigned-big>>, FirstPeer} = rocksdb:iterator_move(Iterator, first),
    {ok, <<End:(33*8)/integer-unsigned-big>>, _} = rocksdb:iterator_move(Iterator, last),
    Difference = End - Start,
    case Difference of
        0 ->
            rocksdb:iterator_close(Iterator),
            %% only have one peer
            case lists:member(FirstAddr, Exclude) of
                true ->
                    %% only peer we have is excluded
                    false;
                false ->
                    %% use unsafe coming off the disk
                    try libp2p_peer:decode_unsafe(FirstPeer) of
                        Peer -> {FirstAddr, Peer}
                    catch
                        _:_ ->
                            %% only peer we have is junk
                            false
                    end
            end;
        _ ->
            Offset = rand:uniform(Difference),
            SeekPoint = Start + Offset,
            fun RandLoop(_, 0) ->
                    rocksdb:iterator_close(Iterator),
                    false;
                RandLoop({error, iterator_closed}, T) ->
                    %% start completely over because our iterator is bad
                    random(Peerbook, Exclude, T - 1);
                RandLoop({error, _} = _E, T) ->
                    RandLoop(rocksdb:iterator_move(Iterator, first), T - 1);
                RandLoop({ok, Addr, Bin}, T) ->
                    case lists:member(Addr, Exclude) of
                        true ->
                            RandLoop(rocksdb:iterator_move(Iterator, next), T - 1);
                        false ->
                            %% use unsafe coming off the disk
                            try libp2p_peer:decode_unsafe(Bin) of
                                Peer ->
                                    case libp2p_peer:is_stale(Peer, StaleTime) of
                                        true ->
                                            RandLoop(rocksdb:iterator_move(Iterator, next), T - 1);
                                        false ->
                                            case Pred(Peer) of
                                                true ->
                                                    rocksdb:iterator_close(Iterator),
                                                    {Addr, Peer};
                                                _ ->
                                                    RandLoop(rocksdb:iterator_move(Iterator, next), T - 1)
                                            end
                                    end
                             catch
                                _:_ ->
                                    RandLoop(rocksdb:iterator_move(Iterator, next), T - 1)
                            end
                    end
            end(rocksdb:iterator_move(Iterator, <<SeekPoint:(33*8)/integer-unsigned-big>>), Tries)
    end.

-spec refresh(peerbook(), libp2p_crypto:pubkey_bin() | libp2p_peer:peer()) -> ok.
refresh(#peerbook{tid=TID}=Handle, ID) when is_binary(ID) ->
    ThisPeerID = libp2p_swarm:pubkey_bin(TID),
    case ThisPeerID == ID of
        true ->
            ok;
        false ->
            case fetch_peer(ID, Handle) of
                {error, _Error} ->
                    GossipGroup = libp2p_swarm:gossip_group(TID),
                    libp2p_peer_resolution:resolve(GossipGroup, ID, 0),
                    ok;
                {ok, Peer} ->
                    refresh(Handle, Peer)
            end
    end;
refresh(#peerbook{tid=TID}, Peer) ->
    TimeDiffMinutes = application:get_env(libp2p, similarity_time_diff_mins, 1),
    case libp2p_peer:network_id_allowable(Peer, libp2p_swarm:network_id(TID)) andalso
         libp2p_peer:is_stale(Peer, timer:minutes(TimeDiffMinutes)) of
        false ->
            ok;
        true ->
            GossipGroup = libp2p_swarm:gossip_group(TID),
            libp2p_peer_resolution:resolve(GossipGroup, libp2p_peer:pubkey_bin(Peer), libp2p_peer:timestamp(Peer)),
            ok
    end.

-spec is_key(peerbook(), libp2p_crypto:pubkey_bin()) -> boolean().
is_key(Handle=#peerbook{}, ID) ->
    case get(Handle, ID) of
        {error, _} -> false;
        {ok, _} -> true
    end.

-spec keys(peerbook()) -> [libp2p_crypto:pubkey_bin()].
keys(Handle=#peerbook{}) ->
    fetch_keys(Handle).

-spec values(peerbook()) -> [libp2p_peer:peer()].
values(Handle=#peerbook{}) ->
    fetch_peers(Handle).

-spec remove(peerbook(), libp2p_crypto:pubkey_bin()) -> ok | {error, no_delete}.
remove(#peerbook{tid=TID}=Handle, ID) ->
     case ID == libp2p_swarm:pubkey_bin(TID) of
         true -> {error, no_delete};
         false -> delete_peer(ID, Handle)
     end.

-spec stale_time(peerbook()) -> pos_integer().
stale_time(#peerbook{stale_time=StaleTime}) ->
    StaleTime.

-spec blacklist_listen_addr(peerbook(), libp2p_crypto:pubkey_bin(), ListenAddr::string())
                           -> ok | {error, not_found}.
blacklist_listen_addr(Handle=#peerbook{}, ID, ListenAddr) ->
    case unsafe_fetch_peer(ID, Handle) of
        {error, Error} ->
            {error, Error};
        {ok, Peer} ->
            UpdatedPeer = libp2p_peer:blacklist_add(Peer, ListenAddr),
            store_peer(UpdatedPeer, Handle)
    end.

-spec join_notify(peerbook(), pid()) -> ok.
join_notify(#peerbook{tid=TID}, Joiner) ->
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), {join_notify, Joiner}).

-spec register_session(peerbook(), pid(), libp2p_identify:identify()) -> ok.
register_session(#peerbook{tid=TID}, SessionPid, Identify) ->
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), {register_session, SessionPid, Identify}).

-spec unregister_session(peerbook(), pid()) -> ok.
unregister_session(#peerbook{tid=TID}, SessionPid) ->
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), {unregister_session, SessionPid}).

changed_listener(#peerbook{tid=TID}) ->%
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), changed_listener).

-spec update_nat_type(peerbook(), libp2p_peer:nat_type()) -> ok.
update_nat_type(#peerbook{tid=TID}, NatType) ->%
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), {update_nat_type, NatType}).

%% @doc Adds an association under the given type to for the swarm this
%% peerbook is part of. Note that the association _must_ have its
%% signature be valid for the address of the swarm this peerbook is
%% part of.
%%
%% Associations are gossiped with the peer record for the swarm.
%%
%% Note that the given association will replace an existing
%% association with the given type and address of the association.
-spec add_association(peerbook(), AssocType::string(), Assoc::libp2p_peer:association()) -> ok.
add_association(#peerbook{tid=TID}, AssocType, Assoc) ->
    gen_server:cast(libp2p_swarm:peerbook_pid(TID), {add_association, AssocType, Assoc}).

%% @doc Look up all the peers that have a given association type
%% `AssocTyp' and address `AssocAddress' in their associations.
-spec lookup_association(peerbook(), AssocType::string(), AssocAddress::libp2p_crypto:pubkey_bin())
                        -> [libp2p_peer:peer()].
lookup_association(Handle=#peerbook{}, AssocType, AssocAddress) ->
    fold_peers(fun(_Key, Peer, Acc) ->
                       case libp2p_peer:is_association(Peer, AssocType, AssocAddress) of
                           true -> [Peer | Acc];
                           false -> Acc
                       end
               end, [], Handle).

%%
%% Gossip Group
%%

-spec handle_gossip_data(pid(), binary() | [libp2p_peer:peer()], peerbook()) -> noreply.
handle_gossip_data(_StreamPid, DecodedList, Handle) ->
    ?MODULE:put(Handle, DecodedList, true),
    noreply.

-spec init_gossip_data(peerbook()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(Handle=#peerbook{tid=TID}) ->
    [{_, EligiblePeerKeys}] = ets:lookup(TID, peerbook_eligible_gossip_peers),
    case EligiblePeerKeys of
        [] ->
            ok;
        _ ->
            SelectPeer = fun F(0) ->
                                 {error, not_found};
                             F(Try) ->
                                 %% Pick a random peer from the set of eligilble peers
                                 SelectedPeerKey = lists:nth(rand:uniform(length(EligiblePeerKeys)),
                                                             EligiblePeerKeys),
                                 case get(Handle, SelectedPeerKey) of
                                     {ok, P} -> {ok, P};
                                     {error, _} -> F(Try-1)
                                 end
                         end,
            %% Try 10 times to pick a random peer that is actually
            %% available in the peerbook
            case SelectPeer(10) of
                {ok, Peer} -> {send, libp2p_peer:encode_list([Peer])};
                {error, not_found} -> ok
            end
    end.


%%
%% gen_server
%%

start_link(TID, SigFun) ->
    gen_server:start_link(reg_name(TID), ?MODULE, [TID, SigFun], [{hibernate_after, 5000}]).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

init([TID, SigFun]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_peerbook(TID),
    DataDir = libp2p_config:swarm_dir(TID, [peerbook]),
    SwarmName = libp2p_swarm:name(TID),
    Group = group_create(SwarmName),
    Opts = libp2p_swarm:opts(TID),
    ets:insert(TID, {peerbook_eligible_gossip_peers, []}),

    CFOpts = application:get_env(rocksdb, global_opts, []),

    StaleTime = libp2p_config:get_opt(Opts, [?MODULE, stale_time], ?DEFAULT_STALE_TIME),
    PeerTime = libp2p_config:get_opt(Opts, [?MODULE, peer_time], ?DEFAULT_PEER_TIME),
    NotifyTime = libp2p_config:get_opt(Opts, [?MODULE, notify_time], ?DEFAULT_NOTIFY_TIME),
    GossipPeersTimeout = libp2p_config:get_opt(Opts, [?MODULE, gossip_peers_timeout], ?DEFAULT_GOSSIP_PEERS_TIMEOUT),
    MetaDataFun = libp2p_config:get_opt(libp2p_swarm:opts(TID), [libp2p_peerbook, signed_metadata_fun],
                                        fun() -> #{} end),
    self() ! gossip_peers_timeout,
    case libp2p_swarm:peerbook(TID) of
        false ->
            ok = rocksdb:repair(DataDir, []), % This is just in case DB gets corrupted
            case rocksdb:open_with_ttl(DataDir, [{create_if_missing, true}] ++ CFOpts,
                                       (2 * StaleTime) div 1000, false) of
                {error, Reason} -> {stop, Reason};
                {ok, DB} ->
                    %% compact the DB on open, just in case
                    rocksdb:compact_range(DB, undefined, undefined, []),
                    Handle = #peerbook{store=DB, tid=TID, stale_time=StaleTime},
                    GossipGroup = install_gossip_handler(TID, Handle),
                    libp2p_swarm:store_peerbook(TID, Handle),
                    {ok, update_this_peer(
                           get_async_signed_metadata(
                             #state{peerbook = Handle, tid=TID, notify_group=Group, sigfun=SigFun,
                                    peer_time=PeerTime, notify_time=NotifyTime,
                                    gossip_group=GossipGroup,
                                    metadata_fun=MetaDataFun,
                                    gossip_peers_timeout=GossipPeersTimeout}))}
            end;
        Handle ->
            %% we already got a handle in ETS
            GossipGroup = install_gossip_handler(TID, Handle),
            {ok, update_this_peer(
                   get_async_signed_metadata(
                     #state{peerbook = Handle, tid=TID, notify_group=Group, sigfun=SigFun,
                            peer_time=PeerTime, notify_time=NotifyTime,
                            gossip_group=GossipGroup,
                            metadata_fun=MetaDataFun,
                            gossip_peers_timeout=GossipPeersTimeout}))}
    end.

handle_call(update_this_peer, _From, State) ->
    {reply, update_this_peer(State), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({notify_new_peers, Peers}, State) ->
    {noreply, notify_new_peers(Peers, State)};
handle_cast(changed_listener, State=#state{}) ->
    {noreply, update_this_peer(State)};
handle_cast({update_nat_type, UpdatedNatType}, State=#state{}) ->
    {noreply, update_this_peer(State#state{nat_type=UpdatedNatType})};
handle_cast({add_association, AssocType, Assoc}, State=#state{peerbook=Handle}) ->
    %% Fetch our peer record
    SwarmAddr = libp2p_swarm:pubkey_bin(State#state.tid),
    ThisPeer = case unsafe_fetch_peer(SwarmAddr, Handle) of
        {ok, Peer}  -> Peer;
        {error, not_found} -> mk_this_peer(undefined, State)
    end,
    %% Create the new association and put it in the peer
    UpdatedPeer = libp2p_peer:associations_put(ThisPeer, AssocType, Assoc, State#state.sigfun),
    {noreply, update_this_peer(UpdatedPeer, State)};
handle_cast({unregister_session, SessionPid}, State=#state{sessions=Sessions}) ->
    {noreply, update_this_peer(State#state{sessions=maps:remove(SessionPid, Sessions)})};
handle_cast({register_session, SessionPid, Identify},
            State=#state{sessions=Sessions}) ->
    SessionAddr = libp2p_identify:pubkey_bin(Identify),
    {noreply, update_this_peer(State#state{sessions=maps:put(SessionPid, SessionAddr, Sessions)})};
handle_cast({join_notify, JoinPid}, State=#state{notify_group=Group}) ->
    group_join(Group, JoinPid),
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({signed_metadata, MD}, State) ->
    {noreply, State#state{metadata=MD}};
handle_info({'DOWN', Ref, _, _, _}, State=#state{metadata_ref=Ref}) ->
    {noreply, State#state{metadata_ref=undefined}};
handle_info(peer_timeout, State=#state{tid=TID}) ->
    SwarmAddr = libp2p_swarm:pubkey_bin(TID),
    {ok, CurrentPeer} = unsafe_fetch_peer(SwarmAddr, State#state.peerbook),
    NewPeer = mk_this_peer(CurrentPeer, State),
    {noreply, update_this_peer(NewPeer, get_async_signed_metadata(State))};
handle_info(notify_timeout, State=#state{}) ->
    {noreply, notify_peers(State#state{notify_timer=undefined})};
handle_info(gossip_peers_timeout, State=#state{peerbook=Handle, tid=TID}) ->
    %% A peer is eligilble for gossiping if it is dialable and has a
    %% minimum number of outbound connections.
    IsEligibleGossipPeer = fun(Peer) ->
                                   libp2p_peer:is_dialable(Peer)
                                       andalso length(libp2p_peer:connected_peers(Peer)) >= 5
                           end,
    %% TODO longer term use peer updates to update the elegible peers list and avoid folding the peerbook at all
    EligiblePeerKeys = fold_peers(fun(_, Peer, Acc) ->
                                          case IsEligibleGossipPeer(Peer) of
                                              true -> [libp2p_peer:pubkey_bin(Peer) | Acc];
                                              false -> Acc
                                       end
                               end, [], Handle),
    ets:insert(TID, {peerbook_eligible_gossip_peers, EligiblePeerKeys}),
    NewTimer = erlang:send_after(State#state.gossip_peers_timeout, self(), gossip_peers_timeout),
    {noreply, State#state{gossip_peers_timer=NewTimer}};

handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.

terminate(shutdown, #state{peerbook=#peerbook{store=Store}}) ->
    %% only close the db on shutdown
    rocksdb:close(Store);
terminate(_Reason, _State) ->
    ok.


%%
%% Internal
%%

-spec mk_this_peer(libp2p_peer:peer() | undefined, #state{}) -> {ok, libp2p_peer:peer()} | {error, term()}.
mk_this_peer(CurrentPeer, State=#state{tid=TID}) ->
    SwarmAddr = libp2p_swarm:pubkey_bin(TID),
    AllowRFC1918 = is_rfc1918_allowed(TID),
    ListenAddrs0 = libp2p_config:listen_addrs(TID),
    ListenAddrs = case AllowRFC1918 of
                      true ->
                          %% everything is ok
                          ListenAddrs0;
                      false ->
                          filter_rfc1918_addresses(ListenAddrs0)
                  end,
    NetworkID = libp2p_swarm:network_id(TID),
    ConnectedAddrs = maps:values(State#state.sessions),
    %% Copy data from current peer
    case CurrentPeer of
        undefined ->
            Associations = [];
        _ ->
            Associations = libp2p_peer:associations(CurrentPeer)
    end,
    libp2p_peer:from_map(#{ pubkey => SwarmAddr,
                            listen_addrs => ListenAddrs,
                            connected => ConnectedAddrs,
                            nat_type => State#state.nat_type,
                            network_id => NetworkID,
                            associations => Associations,
                            signed_metadata => State#state.metadata},
                         State#state.sigfun).

-spec update_this_peer(#state{}) -> #state{}.
update_this_peer(State=#state{tid=TID}) ->
    case application:get_env(libp2p, seed_node, false) of
        false ->
            SwarmAddr = libp2p_swarm:pubkey_bin(TID),
            case unsafe_fetch_peer(SwarmAddr, State#state.peerbook) of
                {error, not_found} ->
                    NewPeer = mk_this_peer(undefined, State),
                    update_this_peer(NewPeer, get_async_signed_metadata(State));
                {ok, OldPeer} ->
                    case mk_this_peer(OldPeer, State) of
                        {ok, NewPeer} ->
                            case libp2p_peer:is_similar(NewPeer, OldPeer) of
                                true -> State;
                                false -> update_this_peer({ok, NewPeer}, get_async_signed_metadata(State))
                            end;
                        {error, Error} ->
                            lager:notice("Failed to make peer: ~p", [Error]),
                            State
                    end
            end;
         true ->
            State
    end.

-spec update_this_peer({ok, libp2p_peer:peer()} | {error, term()}, #state{}) -> #state{}.
update_this_peer({error, _Error}, State=#state{peer_timer=PeerTimer}) ->
    case PeerTimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(PeerTimer)
    end,
    NewPeerTimer = erlang:send_after(State#state.peer_time, self(), peer_timeout),
    State#state{peer_timer=NewPeerTimer};
update_this_peer({ok, NewPeer}, State=#state{peer_timer=PeerTimer}) ->
    store_peer(NewPeer, State#state.peerbook),
    case PeerTimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(PeerTimer)
    end,
    NewPeerTimer = erlang:send_after(State#state.peer_time, self(), peer_timeout),
    notify_new_peers([NewPeer], State#state{peer_timer=NewPeerTimer}).

-spec notify_new_peers([libp2p_peer:peer()], #state{}) -> #state{}.
notify_new_peers([], State=#state{}) ->
    State;
notify_new_peers(NewPeers, State=#state{notify_timer=NotifyTimer, notify_time=NotifyTime,
                                        notify_peers=NotifyPeers}) ->
    %% Cache the new peers to be sent out but make sure that the new
    %% peers are not stale.  We do that by only replacing already
    %% cached versions if the new peers supersede existing ones
    NewNotifyPeers = lists:foldl(
                       fun (Peer, Acc) ->
                               %% check the peer has some interesting information
                               case has_useful_listen_addrs(Peer, State) orelse
                                    libp2p_peer:connected_peers(Peer) /= [] of
                                   false -> Acc;
                                   true ->
                                       case maps:find(libp2p_peer:pubkey_bin(Peer), Acc) of
                                           error -> maps:put(libp2p_peer:pubkey_bin(Peer), Peer, Acc);
                                           {ok, FoundPeer} ->
                                               case libp2p_peer:supersedes(Peer, FoundPeer) of
                                                   true -> maps:put(libp2p_peer:pubkey_bin(Peer), Peer, Acc);
                                                   false -> Acc
                                               end
                                       end
                               end
                       end, NotifyPeers, NewPeers),
    %% Set up a timer if ntot already set. This ensures that fast new
    %% peers will keep notifications ticking at the notify_time, but
    %% that no timer is firing if there's nothing to notify.
    NewNotifyTimer = case NotifyTimer of
                         undefined when map_size(NewNotifyPeers) > 0 ->
                             erlang:send_after(NotifyTime, self(), notify_timeout);
                         Other -> Other
                     end,
    State#state{notify_peers=NewNotifyPeers, notify_timer=NewNotifyTimer}.

-spec has_useful_listen_addrs(libp2p_peer:peer(), #state{}) -> boolean().
has_useful_listen_addrs(Peer, #state{tid=TID}) ->
    Opts = libp2p_swarm:opts(TID),
    AllowRFC1918 = libp2p_config:get_opt(Opts, [?MODULE, allow_rfc1918], ?DEFAULT_PEERBOOK_ALLOW_RFC1918),
    ListenAddrs0 = libp2p_peer:listen_addrs(Peer),
    ListenAddrs = case AllowRFC1918 of
                      true ->
                          %% everything is ok
                          ListenAddrs0;
                      false ->
                          filter_rfc1918_addresses(ListenAddrs0)
                  end,
    ListenAddrs /= [].

filter_rfc1918_addresses(ListenAddrs) ->
    %% filter out any rfc1918 addresses
    lists:filter(fun(A) -> libp2p_transport_tcp:rfc1918(A) == false end, ListenAddrs).

-spec notify_peers(#state{}) -> #state{}.
notify_peers(State=#state{notify_peers=NotifyPeers}) when map_size(NotifyPeers) == 0 ->
    State;
notify_peers(State=#state{notify_peers=NotifyPeers, notify_group=NotifyGroup,
                          gossip_group=GossipGroup, tid=TID}) ->
    %% Notify to local interested parties
    PeerList = maps:values(NotifyPeers),
    [Pid ! {new_peers, PeerList} || Pid <- pg2:get_members(NotifyGroup)],

    case GossipGroup of
        undefined ->
            ok;
        _ ->
            Opts = libp2p_swarm:opts(TID),
            PeerCount = libp2p_config:get_opt(Opts, [?MODULE, notify_peer_gossip_limit], ?DEFAULT_NOTIFY_PEER_GOSSIP_LIMIT),
            %% Gossip to any attached parties
            SendFun = fun() ->
                              {_, RandomNPeers} = lists:unzip(lists:sublist(lists:keysort(1, [ {rand:uniform(), E} || E <- PeerList]), PeerCount)),
                              libp2p_peer:encode_list(RandomNPeers)
                      end,
            libp2p_group_gossip:send(GossipGroup, ?GOSSIP_GROUP_KEY, SendFun)
    end,
    State#state{notify_peers=#{}}.


%% rocksdb has a bad spec that doesn't list corruption as a valid return
%% so this is here until that gets fixed
-dialyzer({nowarn_function, unsafe_fetch_peer/2}).
-spec unsafe_fetch_peer(libp2p_crypto:pubkey_bin() | undefined, peerbook())
                       -> {ok, libp2p_peer:peer()} | {error, not_found}.
unsafe_fetch_peer(undefined, _) ->
    {error, not_found};
unsafe_fetch_peer(ID, #peerbook{store=Store}) ->
    case rocksdb:get(Store, ID, []) of
        {ok, Bin} ->
            %% I think that it's OK to use unsafe here for performance, this was validated on
            %% storage.  disk corruption will result in a crash anyway.
            try libp2p_peer:decode_unsafe(Bin) of
                Peer -> {ok, Peer}
            catch
                _:_ ->
                    {error, not_found}
            end;
        %% we can get 'corruption' when the system time is not at least 05/09/2013:5:40PM GMT-8
        %% https://github.com/facebook/rocksdb/blob/4decff6fa8c4d46e905a66d439394c4bfb889a69/utilities/ttl/db_ttl_impl.cc#L154
        corruption -> {error, not_found};
        {error, {corruption, _}} -> {error, not_found};
        not_found -> {error, not_found}
    end.

-spec fetch_peer(libp2p_crypto:pubkey_bin(), peerbook())
                -> {ok, libp2p_peer:peer()} | {error, term()}.
fetch_peer(ID, Handle=#peerbook{stale_time=StaleTime}) ->
    case unsafe_fetch_peer(ID, Handle) of
        {ok, Peer} ->
            case libp2p_peer:is_stale(Peer, StaleTime) of
                true -> {error, not_found};
                false -> {ok, Peer}
            end;
        {error, Error} -> {error,Error}
    end.


fold_peers(Fun, Acc0, #peerbook{tid=TID, store=Store, stale_time=StaleTime}) ->
    {ok, Iterator} = rocksdb:iterator(Store, []),
    NetworkID = libp2p_swarm:network_id(TID),
    fold(Iterator, rocksdb:iterator_move(Iterator, first),
         fun(Key, Bin, Acc) ->
                 Peer = libp2p_peer:decode_unsafe(Bin),
                 case libp2p_peer:is_stale(Peer, StaleTime)
                     orelse not libp2p_peer:network_id_allowable(Peer, NetworkID) of
                     true -> Acc;
                     false -> Fun(Key, Peer, Acc)
                 end
         end, Acc0).

fold(Iterator, {error, _}, _Fun, Acc) ->
    rocksdb:iterator_close(Iterator),
    Acc;
fold(Iterator, {ok, Key, Value}, Fun, Acc) ->
    fold(Iterator, rocksdb:iterator_move(Iterator, next), Fun, Fun(Key, Value, Acc)).

-spec fetch_keys(peerbook()) -> [libp2p_crypto:pubkey_bin()].
fetch_keys(State=#peerbook{}) ->
    fold_peers(fun(Key, _, Acc) -> [Key | Acc] end, [], State).

-spec fetch_peers(peerbook()) -> [libp2p_peer:peer()].
fetch_peers(State=#peerbook{}) ->
    fold_peers(fun(_, Peer, Acc) -> [Peer | Acc] end, [], State).

-spec store_peer(libp2p_peer:peer(), peerbook()) -> ok | {error, term()}.
store_peer(Peer, #peerbook{store=Store}) ->
    case rocksdb:put(Store, libp2p_peer:pubkey_bin(Peer), libp2p_peer:encode(Peer), []) of
        {error, Error} -> {error, Error};
        ok -> ok
    end.

-spec delete_peer(libp2p_crypto:pubkey_bin(), peerbook()) -> ok.
delete_peer(ID, #peerbook{store=Store}) ->
    rocksdb:delete(Store, ID, []).

-spec group_create(atom()) -> atom().
group_create(SwarmName) ->
    Name = list_to_atom(filename:join(SwarmName, peerbook)),
    ok = pg2:create(Name),
    Name.

group_join(Group, Pid) ->
    %% only allow a pid to join once
    case lists:member(Pid, pg2:get_members(Group)) of
        false ->
            ok = pg2:join(Group, Pid);
        true ->
            ok
    end.

install_gossip_handler(TID, Handle) ->
    %% We catch exceptions here because the peerbook can work
    %% _without_ a gossip group. The tests for peerbook use this to
    %% isolate tetsing of a peerbook without having to construct a
    %% gossip group too
    case (catch libp2p_swarm:gossip_group(TID)) of
        {'EXIT', _} -> undefined;
        G ->
            libp2p_group_gossip:add_handler(G,  ?GOSSIP_GROUP_KEY, {?MODULE, Handle}),
            libp2p_peer_resolution:install_handler(G, Handle),
            G
    end.

get_async_signed_metadata(State = #state{metadata_ref=undefined, metadata_fun=MetaDataFun}) ->
    Parent = self(),
    {_, Ref} = spawn_monitor(fun() ->
                                     Parent ! {signed_metadata, MetaDataFun()}
                             end),
    State#state{metadata_ref=Ref};
get_async_signed_metadata(State) ->
    %% metadata fun still running
    State.

is_rfc1918_allowed(TID) ->
    Opts = libp2p_swarm:opts(TID),
    libp2p_config:get_opt(Opts, [?MODULE, allow_rfc1918], ?DEFAULT_PEERBOOK_ALLOW_RFC1918).

