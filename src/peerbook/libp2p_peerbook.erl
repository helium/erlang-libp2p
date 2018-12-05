-module(libp2p_peerbook).

-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).
-export([keys/1, values/1, put/2,get/2, is_key/2, remove/2,
         join_notify/2, changed_listener/1, update_nat_type/2,
         register_session/3, unregister_session/2, blacklist_listen_addr/3,
         add_association/3, lookup_association/3]).
%% libp2p_group_gossip_handler
-export([handle_gossip_data/2, init_gossip_data/1]).

-type opt() :: {stale_time, pos_integer()}
             | {peer_time, pos_integer()}.

-export_type([opt/0]).

-behviour(gen_server).
-behavior(libp2p_group_gossip_handler).

-record(state,
        { tid :: ets:tab(),
          store :: rocksdb:db_handle(),
          nat_type = unknown :: libp2p_peer:nat_type(),
          peer_time :: pos_integer(),
          peer_timer :: undefined | reference(),
          stale_time :: pos_integer(),
          gossip_group :: undefined | pid(),
          notify_group :: atom(),
          notify_time :: pos_integer(),
          notify_timer=undefined :: reference() | undefined,
          notify_peers=#{} :: #{libp2p_crypto:address() => libp2p_peer:peer()},
          sessions=[] :: [{libp2p_crypto:address(), pid()}],
          sigfun :: fun((binary()) -> binary())
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

%%
%% API
%%

-spec put(pid(), [libp2p_peer:peer()]) -> ok | {error, term()}.
put(Pid, PeerList) ->
    lists:foreach(fun libp2p_peer:verify/1, PeerList),
    gen_server:call(Pid, {put, PeerList, self()}).

-spec get(pid(), libp2p_crypto:address()) -> {ok, libp2p_peer:peer()} | {error, term()}.
get(Pid, ID) ->
    gen_server:call(Pid, {get, ID}).

-spec is_key(pid(), libp2p_crypto:address()) -> boolean().
is_key(Pid, ID) ->
    gen_server:call(Pid, {is_key, ID}).

-spec keys(pid()) -> [libp2p_crypto:address()].
keys(Pid) ->
    gen_server:call(Pid, keys).

-spec values(pid()) -> [libp2p_peer:peer()].
values(Pid) ->
    gen_server:call(Pid, values).

-spec remove(pid(), libp2p_crypto:address()) -> ok | {error, no_delete}.
remove(Pid, ID) ->
    gen_server:call(Pid, {remove, ID}).

-spec blacklist_listen_addr(pid(), libp2p_crypto:address(), ListenAddr::string())
                           -> ok | {error, not_found}.
blacklist_listen_addr(Pid, ID, ListenAddr) ->
    gen_server:call(Pid, {blacklist_listen_addr, ID, ListenAddr}).

-spec join_notify(pid(), pid()) -> ok.
join_notify(Pid, Joiner) ->
    gen_server:cast(Pid, {join_notify, Joiner}).

-spec register_session(pid(), pid(), libp2p_identify:identify()) -> ok.
register_session(Pid, SessionPid, Identify) ->
    gen_server:cast(Pid, {register_session, SessionPid, Identify}).

-spec unregister_session(pid(), pid()) -> ok.
unregister_session(Pid, SessionPid) ->
    gen_server:cast(Pid, {unregister_session, SessionPid}).

changed_listener(Pid) ->
    gen_server:cast(Pid, changed_listener).

-spec update_nat_type(pid(), libp2p_peer:nat_type()) -> ok.
update_nat_type(Pid, NatType) ->
    gen_server:cast(Pid, {update_nat_type, NatType}).

%% @doc Adds an association under the given type to for the swarm this
%% peerbook is part of. Note that the association _must_ have its
%% signature be valid for the address of the swarm this peerbook is
%% part of.
%%
%% Associations are gossiped with the peer record for the swarm.
%%
%% Note that the given association will replace an existing
%% association with the given type and address of the association.
-spec add_association(pid(), AssocType::string(), Assoc::libp2p_peer:association()) -> ok.
add_association(Pid, AssocType, Assoc) ->
    gen_server:cast(Pid, {add_association, AssocType, Assoc}).

%% @doc Look up all the peers that have a given association type
%% `AssocTyp' and address `AssocAddress' in their associations.
-spec lookup_association(pid(), AssocType::string(), AssocAddress::libp2p_crypto:address())
                        -> [libp2p_peer:peer()].
lookup_association(Pid, AssocType, AssocAddress) ->
    gen_server:call(Pid, {lookup_association, AssocType, AssocAddress}).

%%
%% Gossip Group
%%

-spec handle_gossip_data(binary(), pid()) -> ok.
handle_gossip_data(Data, Pid) ->
    DecodedList = libp2p_peer:decode_list(Data),
    libp2p_peerbook:put(Pid, DecodedList).

-spec init_gossip_data(pid()) -> libp2p_group_gossip_handler:init_result().
init_gossip_data(Pid) ->
    gen_server:call(Pid, init_gossip_data).


%%
%% gen_server
%%

start_link(TID, SigFun) ->
    gen_server:start_link(?MODULE, [TID, SigFun], []).

init([TID, SigFun]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_peerbook(TID),
    DataDir = libp2p_config:swarm_dir(TID, [peerbook]),
    SwarmName = libp2p_swarm:name(TID),
    Group = group_create(SwarmName),
    Opts = libp2p_swarm:opts(TID),
    StaleTime = libp2p_config:get_opt(Opts, [?MODULE, stale_time], ?DEFAULT_STALE_TIME),
    %% We catch exceptions here because the peerbook can work
    %% _without_ a gossip group. The tests for peerbook use this to
    %% isolate tetsing of a peerbook without having to construct a
    %% gossip group too
    GossipGroup = case (catch libp2p_swarm:gossip_group(TID)) of
                      {'EXIT', _} -> undefined;
                      G ->
                          libp2p_group_gossip:add_handler(G,  ?GOSSIP_GROUP_KEY, {?MODULE, self()}),
                          G
                  end,
    case rocksdb:open_with_ttl(DataDir, [{create_if_missing, true}], (2 * StaleTime) div 1000, false) of
        {error, Reason} -> {stop, Reason};
        {ok, DB} ->
            PeerTime = libp2p_config:get_opt(Opts, [?MODULE, peer_time], ?DEFAULT_PEER_TIME),
            NotifyTime = libp2p_config:get_opt(Opts, [?MODULE, notify_time], ?DEFAULT_NOTIFY_TIME),
            {ok, update_this_peer(#state{tid=TID, store=DB, notify_group=Group, sigfun=SigFun,
                                         peer_time=PeerTime, notify_time=NotifyTime,
                                         stale_time=StaleTime, gossip_group=GossipGroup})}
    end.


handle_call({is_key, ID}, _From, State=#state{}) ->
    Response = try
                   fold_peers(fun(Key, _, _) when Key == ID ->
                                      throw({ok, ID});
                                 (_, _, Acc) -> Acc
                              end, false, State)
               catch
                   throw:{ok, ID} -> true
               end,
    {reply, Response, State};
handle_call(keys, _From, State=#state{}) ->
    {reply, fetch_keys(State), State};
handle_call(values, _From, State=#state{}) ->
    {reply, fetch_peers(State), State};
handle_call({get, ID}, _From, State=#state{tid=TID}) ->
    ThisPeerID = libp2p_swarm:address(TID),
    case fetch_peer(ID, State) of
        {error, not_found} when ID == ThisPeerID ->
            NewState = update_this_peer(State),
            {reply, fetch_peer(ID, NewState), NewState};
        {error, Error} ->
            {reply, {error, Error}, State};
        {ok, Peer} ->
            {reply, {ok, Peer}, State}
    end;
handle_call({put, PeerList, _}, _From, State=#state{tid=TID, stale_time=StaleTime}) ->
    ThisPeerId = libp2p_swarm:address(TID),
    NewPeers = lists:filter(fun(NewPeer) ->
                                    NewPeerId = libp2p_peer:address(NewPeer),
                                    case unsafe_fetch_peer(NewPeerId, State) of
                                        {error, not_found} -> true;
                                        {ok, ExistingPeer} ->
                                            %% Only store peers that are not _this_ peer,
                                            %% are newer than what we have,
                                            %% are not stale themselves
                                            NewPeerId /= ThisPeerId
                                                andalso libp2p_peer:supersedes(NewPeer, ExistingPeer)
                                                andalso not libp2p_peer:is_stale(NewPeer, StaleTime)
                                    end
                            end, PeerList),

    % Add new peers to the store
    lists:foreach(fun(P) -> store_peer(P, State) end, NewPeers),
    % Notify group of new peers
    {reply, ok, notify_new_peers(NewPeers, State)};
handle_call({remove, ID}, _From, State=#state{tid=TID}) ->
    Result = case ID == libp2p_swarm:address(TID) of
                 true -> {error, no_delete};
                 false -> delete_peer(ID, State)
             end,
    {reply, Result, State};
handle_call(init_gossip_data, _From, State=#state{}) ->
    Peers = fetch_peers(State),
    {reply, {send, libp2p_peer:encode_list(Peers)}, State};
handle_call({blacklist_listen_addr, ID, ListenAddr}, _From, State=#state{}) ->
    case unsafe_fetch_peer(ID, State) of
        {error, Error} ->
            {reply, {error, Error}, State};
        {ok, Peer} ->
            UpdatedPeer = libp2p_peer:blacklist_add(Peer, ListenAddr),
            store_peer(UpdatedPeer, State),
            {reply, ok, State}
    end;
handle_call({lookup_association, AssocType, AssocAddress}, _From, State=#state{}) ->
    Peers = fold_peers(fun(_Key, Peer, Acc) ->
                               case libp2p_peer:is_association(Peer, AssocType, AssocAddress) of
                                   true -> [Peer | Acc];
                                   false -> Acc
                               end
                       end, [], State),
    {reply, Peers, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(changed_listener, State=#state{}) ->
    {noreply, update_this_peer(State)};
handle_cast({update_nat_type, UpdatedNatType}, State=#state{}) ->
    {noreply, update_this_peer(State#state{nat_type=UpdatedNatType})};
handle_cast({add_association, AssocType, Assoc}, State=#state{}) ->
    %% Fetch our peer record
    SwarmAddr = libp2p_swarm:address(State#state.tid),
    {ok, ThisPeer} = unsafe_fetch_peer(SwarmAddr, State),
    %% Create the new association and put it in the peer
    UpdatedPeer = libp2p_peer:associations_put(ThisPeer, AssocType, Assoc, State#state.sigfun),
    {noreply, update_this_peer(UpdatedPeer, State)};
handle_cast({unregister_session, SessionPid}, State=#state{sessions=Sessions}) ->
    NewSessions = lists:filter(fun({_Addr, Pid}) -> Pid /= SessionPid end, Sessions),
    {noreply, update_this_peer(State#state{sessions=NewSessions})};
handle_cast({register_session, SessionPid, Identify},
            State=#state{sessions=Sessions}) ->
    SessionAddr = libp2p_identify:address(Identify),
    NewSessions = [{SessionAddr, SessionPid} | Sessions],
    {noreply, update_this_peer(State#state{sessions=NewSessions})};
handle_cast({join_notify, JoinPid}, State=#state{notify_group=Group}) ->
    group_join(Group, JoinPid),
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info(peer_timeout, State=#state{tid=TID}) ->
    SwarmAddr = libp2p_swarm:address(TID),
    {ok, CurrentPeer} = unsafe_fetch_peer(SwarmAddr, State),
    {noreply, update_this_peer(mk_this_peer(CurrentPeer, State), State)};
handle_info(notify_timeout, State=#state{}) ->
    {noreply, notify_peers(State#state{notify_timer=undefined})};

handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{store=Store}) ->
    rocksdb:close(Store).


%%
%% Internal
%%

-spec mk_this_peer(libp2p_peer:peer() | undefined, #state{}) -> libp2p_peer:peer().
mk_this_peer(CurrentPeer, State=#state{tid=TID}) ->
    SwarmAddr = libp2p_swarm:address(TID),
    ListenAddrs = libp2p_config:listen_addrs(TID),
    ConnectedAddrs = sets:to_list(sets:from_list([Addr || {Addr, _} <- State#state.sessions])),
    %% Copy data from current peer
    case CurrentPeer of
        undefined ->
            Associations = [];
        _ ->
            Associations = libp2p_peer:associations(CurrentPeer)
    end,
    libp2p_peer:from_map(#{ address => SwarmAddr,
                            listen_addrs => ListenAddrs,
                            connected => ConnectedAddrs,
                            nat_type => State#state.nat_type,
                            associations => Associations},
                         State#state.sigfun).

-spec update_this_peer(#state{}) -> #state{}.
update_this_peer(State=#state{tid=TID}) ->
    SwarmAddr = libp2p_swarm:address(TID),
    case unsafe_fetch_peer(SwarmAddr, State) of
        {error, not_found} ->
            NewPeer = mk_this_peer(undefined, State),
            update_this_peer(NewPeer, State);
        {ok, OldPeer} ->
            NewPeer = mk_this_peer(OldPeer, State),
            case libp2p_peer:is_similar(NewPeer, OldPeer) of
                true -> State;
                false -> update_this_peer(NewPeer, State)
            end
    end.

-spec update_this_peer(libp2p_peer:peer(), #state{}) -> #state{}.
update_this_peer(NewPeer, State=#state{peer_timer=PeerTimer}) ->
    store_peer(NewPeer, State),
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
                                        notify_peers=NotifyPeers, stale_time=_StaleTime}) ->
    %% Cache the new peers to be sent out but make sure that the new
    %% peers are not stale.  We do that by only replacing already
    %% cached versions if the new peers supersede existing ones
    NewNotifyPeers = lists:foldl(
                       fun (Peer, Acc) ->
                               case maps:find(libp2p_peer:address(Peer), Acc) of
                                   error -> maps:put(libp2p_peer:address(Peer), Peer, Acc);
                                   {ok, FoundPeer} ->
                                       case libp2p_peer:supersedes(Peer, FoundPeer) of
                                           true -> maps:put(libp2p_peer:address(Peer), Peer, Acc);
                                           false -> Acc
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

-spec notify_peers(#state{}) -> #state{}.
notify_peers(State=#state{notify_peers=NotifyPeers}) when map_size(NotifyPeers) == 0 ->
    State;
notify_peers(State=#state{notify_peers=NotifyPeers, notify_group=NotifyGroup,
                          gossip_group=GossipGroup}) ->
    %% Notify to local interested parties
    PeerList = maps:values(NotifyPeers),
    [Pid ! {new_peers, PeerList} || Pid <- pg2:get_members(NotifyGroup)],
    case GossipGroup of
        undefined ->
            ok;
        _ ->
            %% Gossip to any attached parties
            EncodedPeerList = libp2p_peer:encode_list(PeerList),
            libp2p_group_gossip:send(GossipGroup, ?GOSSIP_GROUP_KEY, EncodedPeerList)
    end,
    State#state{notify_peers=#{}}.


%% rocksdb has a bad spec that doesn't list corruption as a valid return
%% so this is here until that gets fixed
-dialyzer({nowarn_function, unsafe_fetch_peer/2}).
-spec unsafe_fetch_peer(libp2p_crypto:address() | undefined, #state{})
                       -> {ok, libp2p_peer:peer()} | {error, term()}.
unsafe_fetch_peer(undefined, _) ->
    {error, not_found};
unsafe_fetch_peer(ID, #state{store=Store}) ->
    case rocksdb:get(Store, ID, []) of
        {ok, Bin} -> {ok, libp2p_peer:decode(Bin)};
        %% we can get 'corruption' when the system time is not at least 05/09/2013:5:40PM GMT-8
        %% https://github.com/facebook/rocksdb/blob/4decff6fa8c4d46e905a66d439394c4bfb889a69/utilities/ttl/db_ttl_impl.cc#L154
        corruption -> {error, not_found};
        not_found -> {error, not_found}
    end.

-spec fetch_peer(libp2p_crypto:address(), #state{})
                -> {ok, libp2p_peer:peer()} | {error, term()}.
fetch_peer(ID, State=#state{stale_time=StaleTime}) ->
    case unsafe_fetch_peer(ID, State) of
        {ok, Peer} ->
            case libp2p_peer:is_stale(Peer, StaleTime) of
                true -> {error, not_found};
                false -> {ok, Peer}
            end;
        {error, Error} -> {error,Error}
    end.


fold_peers(Fun, Acc0, #state{store=Store, stale_time=StaleTime}) ->
    {ok, Iterator} = rocksdb:iterator(Store, []),
    fold(Iterator, rocksdb:iterator_move(Iterator, first),
         fun(Key, Bin, Acc) ->
                 Peer = libp2p_peer:decode(Bin),
                 case libp2p_peer:is_stale(Peer, StaleTime) of
                     true -> Acc;
                     false -> Fun(Key, Peer, Acc)
                 end
         end, Acc0).

fold(Iterator, {error, _}, _Fun, Acc) ->
    rocksdb:iterator_close(Iterator),
    Acc;
fold(Iterator, {ok, Key, Value}, Fun, Acc) ->
    fold(Iterator, rocksdb:iterator_move(Iterator, next), Fun, Fun(Key, Value, Acc)).

-spec fetch_keys(#state{}) -> [libp2p_crypto:address()].
fetch_keys(State=#state{}) ->
    fold_peers(fun(Key, _, Acc) -> [Key | Acc] end, [], State).

-spec fetch_peers(#state{}) -> [libp2p_peer:peer()].
fetch_peers(State=#state{}) ->
    fold_peers(fun(_, Peer, Acc) -> [Peer | Acc] end, [], State).

-spec store_peer(libp2p_peer:peer(), #state{}) -> ok | {error, term()}.
store_peer(Peer, #state{store=Store}) ->
    case rocksdb:put(Store, libp2p_peer:address(Peer), libp2p_peer:encode(Peer), []) of
        {error, Error} -> {error, Error};
        ok -> ok
    end.

-spec delete_peer(libp2p_crypto:address(), #state{}) -> ok.
delete_peer(ID, #state{store=Store}) ->
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
