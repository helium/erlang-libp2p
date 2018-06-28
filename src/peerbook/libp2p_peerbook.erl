-module(libp2p_peerbook).

-include_lib("bitcask/include/bitcask.hrl").

-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).
-export([keys/1, values/1, put/2,get/2, is_key/2, remove/2,
         join_notify/2, register_session/4,  unregister_session/2,
         changed_listener/1, update_nat_type/2]).

-type opt() :: {stale_time, pos_integer()}
             | {peer_time, pos_integer()}.

-export_type([opt/0]).

-behviour(gen_server).

-record(state,
        { tid :: ets:tab(),
          store :: reference(),
          nat_type = unknown :: libp2p_peer:nat_type(),
          peer_time :: pos_integer(),
          peer_timer :: undefined | reference(),
          stale_time :: pos_integer(),
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

%%
%% API
%%

-spec put(pid(), [libp2p_peer:peer()]) -> ok | {error, term()}.
put(Pid, PeerList) ->
    VerifiedList = [libp2p_peer:verify(L) || L <- PeerList],
    gen_server:call(Pid, {put, VerifiedList, self()}).

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

-spec join_notify(pid(), pid()) -> ok.
join_notify(Pid, Joiner) ->
    gen_server:cast(Pid, {join_notify, Joiner}).

-spec register_session(pid(), pid(), libp2p_identify:identify(), client | server) -> ok.
register_session(Pid, SessionPid, Identify, Kind) ->
    gen_server:cast(Pid, {register_session, SessionPid, Identify, Kind}).

-spec unregister_session(pid(), pid()) -> ok.
unregister_session(Pid, SessionPid) ->
    gen_server:cast(Pid, {unregister_session, SessionPid}).

changed_listener(Pid) ->
    gen_server:cast(Pid, changed_listener).

-spec update_nat_type(pid(), libp2p_peer:nat_type()) -> ok.
update_nat_type(Pid, NatType) ->
    gen_server:cast(Pid, {update_nat_type, NatType}).


%%
%% gen_server
%%

start_link(TID, SigFun) ->
    gen_server:start_link(?MODULE, [TID, SigFun], []).

%% bitcask:open does not pass dialyzer correctly so we turn of the
%% using init/1 function and this_peer since it's only used in
%% init_peer/1
-dialyzer({nowarn_function, [init/1]}).

init([TID, SigFun]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_peerbook(TID),
    DataDir = libp2p_config:swarm_dir(TID, [peerbook]),
    SwarmName = libp2p_swarm:name(TID),
    Group = group_create(SwarmName),
    Opts = libp2p_swarm:opts(TID),
    StaleTime = libp2p_config:get_opt(Opts, [?MODULE, stale_time], ?DEFAULT_STALE_TIME),
    case bitcask:open(DataDir, [read_write, {expiry_secs, 2 * StaleTime / 1000}]) of
        {error, Reason} -> {stop, Reason};
        Ref ->
            PeerTime = libp2p_config:get_opt(Opts, [?MODULE, peer_time], ?DEFAULT_PEER_TIME),
            NotifyTime = libp2p_config:get_opt(Opts, [?MODULE, notify_time], ?DEFAULT_NOTIFY_TIME),
            {ok, update_this_peer(#state{tid=TID, store=Ref, notify_group=Group, sigfun=SigFun,
                                         peer_time=PeerTime, notify_time=NotifyTime,
                                         stale_time=StaleTime})}
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

    %% lager:notice("PEERBOOK ~p ADDING ~p: ~p", [libp2p_crypto:address_to_b58(ThisPeerId),
    %%                                            length(NewPeers),
    %%                                            [libp2p_crypto:address_to_b58(libp2p_peer:address(P))
    %%                                             || P <- NewPeers]]),
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

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(changed_listener, State=#state{}) ->
    {noreply, update_this_peer(State)};
handle_cast({update_nat_type, UpdatedNatType},
            State=#state{nat_type=NatType}) when UpdatedNatType /= NatType->
    {noreply, update_this_peer(State#state{nat_type=UpdatedNatType})};
handle_cast({unregister_session, SessionPid}, State=#state{sessions=Sessions}) ->
    NewSessions = lists:filter(fun({_Addr, Pid}) -> Pid /= SessionPid end, Sessions),
    {noreply, update_this_peer(State#state{sessions=NewSessions})};
handle_cast({register_session, SessionPid, Identify, Kind},
            State=#state{tid=TID, sessions=Sessions}) ->
    SessionAddr = libp2p_identify:address(Identify),
    NewSessions = [{SessionAddr, SessionPid} | Sessions],
    NewState = update_this_peer(State#state{sessions=NewSessions}),

    case Kind of
        client ->
            try
                {_, RemoteAddr} = libp2p_session:addr_info(SessionPid),
                lager:info("Starting discovery with ~p", [RemoteAddr]),
                %% Pass the peerlist directly into the stream_peer client
                %% since it is a synchronous call
                %%
                %% TODO: Can this be moved into a higher level by
                %% using a group_gosip to gossip peers instead of
                %% eagerly exchanging peers on every new connection?
                PeerList = fetch_peers(NewState),
                libp2p_session:dial_framed_stream("peer/1.0.0", SessionPid,
                                                  libp2p_stream_peer, [TID, PeerList])
            catch
                _What:_Why -> ok
            end;
        _ -> ok
    end,
    {noreply, NewState};
handle_cast({join_notify, JoinPid}, State=#state{notify_group=Group}) ->
    group_join(Group, JoinPid),
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info(peer_timeout, State=#state{}) ->
    {noreply, update_this_peer(State)};
handle_info(notify_timeout, State=#state{}) ->
    {noreply, notify_peers(State#state{notify_timer=undefined})};
handle_info(Msg, State) ->
    lager:warning("Unhandled peerbook info: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{store=Store}) ->
    bitcask:close(Store).


%%
%% Internal
%%
-spec update_this_peer(#state{}) -> #state{}.
update_this_peer(State=#state{tid=TID, sessions=Sessions, sigfun=SigFun, nat_type=NatType,
                             peer_time=PeerTime, peer_timer=PeerTimer}) ->
    SwarmAddr = libp2p_swarm:address(TID),
    ListenAddrs = libp2p_config:listen_addrs(TID),
    ConnectedAddrs = sets:to_list(sets:from_list([Addr || {Addr, _} <- Sessions])),
    Peer = libp2p_peer:new(SwarmAddr, ListenAddrs, ConnectedAddrs, NatType,
                           erlang:system_time(seconds), SigFun),
    store_peer(Peer, State),
    case PeerTimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(PeerTimer)
    end,
    NewPeerTimer = erlang:send_after(PeerTime, self(), peer_timeout),
    notify_new_peers([Peer], State#state{peer_timer=NewPeerTimer}).


-spec notify_new_peers([libp2p_peer:peer()], #state{}) -> #state{}.
notify_new_peers([], State=#state{}) ->
    State;
notify_new_peers(NewPeers, State=#state{notify_timer=NotifyTimer, notify_time=NotifyTime,
                                        notify_peers=NotifyPeers, stale_time=_StaleTime}) ->
    %% Cache the new peers to be sent out but make sure that the new
    %% peers are not stale we only replace already cached versions if
    %% the new peers supersede existing ones
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
notify_peers(State=#state{notify_peers=NotifyPeers, notify_group=NotifyGroup}) ->
    PeerList = maps:values(NotifyPeers),
    %% lager:info("NOTIFYING PEERS: ~p",
    %%            [[libp2p_crypto:address_to_b58(libp2p_peer:address(P)) || P <- PeerList]]),
    [Pid ! {new_peers, PeerList} || Pid <- pg2:get_members(NotifyGroup)],
    State#state{notify_peers=#{}}.



-spec unsafe_fetch_peer(libp2p_crypto:address() | undefined, #state{})
                       -> {ok, libp2p_peer:peer()} | {error, term()}.
unsafe_fetch_peer(undefined, _) ->
    {error, not_found};
unsafe_fetch_peer(ID, #state{store=Store}) ->
    case bitcask:get(Store, ID) of
        {ok, Bin} -> {ok, libp2p_peer:decode(Bin)};
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
    bitcask:fold(Store, fun(Key, Bin, Acc) ->
                                Peer = libp2p_peer:decode(Bin),
                                case libp2p_peer:is_stale(Peer, StaleTime) of
                                    true -> Acc;
                                    false -> Fun(Key, Peer, Acc)
                                end
                        end, Acc0).

-spec fetch_keys(#state{}) -> [libp2p_crypto:address()].
fetch_keys(State=#state{}) ->
    fold_peers(fun(Key, _, Acc) -> [Key | Acc] end, [], State).

-spec fetch_peers(#state{}) -> [libp2p_peer:peer()].
fetch_peers(State=#state{}) ->
    fold_peers(fun(_, Peer, Acc) -> [Peer | Acc] end, [], State).

-spec store_peer(libp2p_peer:peer(), #state{}) -> ok | {error, term()}.
store_peer(Peer, #state{store=Store}) ->
    case bitcask:put(Store, libp2p_peer:address(Peer), libp2p_peer:encode(Peer)) of
        {error, Error} -> {error, Error};
        ok -> ok
    end.

-spec delete_peer(libp2p_crypto:address(), #state{}) -> ok.
delete_peer(ID, #state{store=Store}) ->
    bitcask:delete(Store, ID).

-spec group_create(atom()) -> atom().
group_create(SwarmName) ->
    Name = list_to_atom(filename:join(SwarmName, peerbook)),
    ok = pg2:create(Name),
    Name.

group_join(Group, Pid) ->
    ok = pg2:join(Group, Pid),
    ok.
