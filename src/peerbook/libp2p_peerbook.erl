-module(libp2p_peerbook).

-include_lib("bitcask/include/bitcask.hrl").

-export([start_link/2, init/1, handle_call/3, handle_info/2, handle_cast/2, terminate/2]).
-export([keys/1, values/1, put/2,get/2, is_key/2,
         join_notify/2, register_session/4,  unregister_session/2,
         changed_listener/1, update_nat_type/2]).

-behviour(gen_server).

-record(state,
        { tid :: ets:tab(),
          store :: reference(),
          notify :: atom(),
          nat_type = unknown :: libp2p_peer:nat_type(),
          stale_time :: integer(),
          stale_timer :: reference(),
          sessions=[] :: [{libp2p_crypto:address(), libp2p_session:pid()}],
          sigfun :: fun((binary()) -> binary())
        }).

-define(DEFAULT_PEER_STALE_TIME, 24 * 60 * 60).

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
    DataDir = libp2p_config:data_dir(TID, peerbook),
    SwarmName = libp2p_swarm:name(TID),
    Group = group_create(SwarmName),
    case bitcask:open(DataDir, [read_write]) of
        {error, Reason} -> {stop, Reason};
        Ref ->
            Opts = libp2p_swarm:opts(TID, []),
            StaleTime = libp2p_config:get_opt(Opts, [peerbook, stale_time],
                                              ?DEFAULT_PEER_STALE_TIME),

            StaleTimer = erlang:send_after(1, self(), stale_timeout),
            State = #state{tid=TID, store=Ref, notify=Group, sigfun=SigFun,
                           stale_timer=StaleTimer, stale_time=StaleTime},
            {ok, State}
    end.


handle_call({is_key, ID}, _From, State=#state{store=Store}) ->
    Response = try
                   bitcask:fold_keys(Store, fun(#bitcask_entry{key=SID}, _) when SID == ID ->
                                                    throw({ok, ID});
                                               (_, Acc) -> Acc
                                            end, false)
               catch
                   throw:{ok, ID} -> true
               end,
    {reply, Response, State};
handle_call(keys, _From, State=#state{store=Store}) ->
    {reply, bitcask:list_keys(Store), State};
handle_call(values, _From, State=#state{store=Store}) ->
    {reply, fetch_peers(Store), State};
handle_call({get, ID}, _From, State=#state{store=Store}) ->
    {reply, fetch_peer(ID, Store), State};
handle_call({put, PeerList, CallerPid}, _From, State=#state{store=Store, notify=Group, tid=TID}) ->
    ThisPeerId = libp2p_swarm:address(TID),
    NewPeers = lists:filter(fun(NewPeer) ->
                                    NewPeerId = libp2p_peer:address(NewPeer),
                                    case fetch_peer(NewPeerId, Store) of
                                        {error, not_found} -> true;
                                        {ok, ExistingPeer} ->
                                            %% Only store peers that are not _this_ peer,
                                            %% are newer than what we have
                                            NewPeerId /= ThisPeerId
                                                andalso libp2p_peer:supersedes(NewPeer, ExistingPeer)
                                    end
                            end, PeerList),
    % Add new peers to the store
    lists:foreach(fun(P) -> store_peer(P, Store) end, NewPeers),
    % Notify group of new peers
    group_notify_peers(Group, CallerPid, NewPeers),
    {reply, ok, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p~n", [Msg]),
    {reply, ok, State}.

handle_cast(changed_listener, State=#state{}) ->
    {noreply, update_this_peer(State)};
handle_cast({update_nat_type, UpdatedNatType},
            State=#state{nat_type=NatType}) when UpdatedNatType /= NatType->
    {noreply, update_this_peer(State)};
handle_cast({unregister_session, SessionPid}, State=#state{sessions=Sessions}) ->
    NewSessions = lists:filter(fun({_Addr, Pid}) -> Pid /= SessionPid end, Sessions),
    {noreply, update_this_peer(State#state{sessions=NewSessions})};
handle_cast({register_session, SessionPid, Identify, Kind},
            State=#state{tid=TID, sessions=Sessions, store=Store}) ->
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
                PeerList = fetch_peers(Store),
                libp2p_session:start_client_framed_stream("peer/1.0.0", SessionPid,
                                                          libp2p_stream_peer, [TID, PeerList])
            catch
                _What:_Why -> ok
            end;
        _ -> ok
    end,
    {noreply, NewState};
handle_cast({join_notify, JoinPid}, State=#state{notify=Group}) ->
    group_join(Group, JoinPid),
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info(stale_timeout, State=#state{}) ->
    {noreply, update_this_peer(State)};
handle_info(Msg, State) ->
    lager:warning("Unhandled info: ~p~n", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{store=Store}) ->
    bitcask:close(Store).


%%
%% Internal
%%


-spec update_this_peer(#state{}) -> #state{}.
update_this_peer(State=#state{notify=Group, stale_time=StaleTime, stale_timer=StaleTimer}) ->
    Peer = mk_this_peer(State),
    group_notify_peers(Group, undefined, [Peer]),
    erlang:cancel_timer(StaleTimer),
    erlang:send_after(StaleTime, self(), stale_timeout),
    State#state{stale_timer=StaleTimer}.

mk_this_peer(#state{tid=TID, sessions=Sessions, sigfun=SigFun, nat_type=NatType, store=Store}) ->
    SwarmAddr = libp2p_swarm:address(TID),
    ListenAddrs = libp2p_config:listen_addrs(TID),
    ConnectedAddrs = sets:to_list(sets:from_list([Addr || {Addr, _} <- Sessions])),
    Peer = libp2p_peer:new(SwarmAddr, ListenAddrs, ConnectedAddrs, NatType,
                           erlang:system_time(seconds), SigFun),
    store_peer(Peer, Store),
    Peer.

-spec fetch_peer(libp2p_crypto:address(), reference())
                -> {ok, libp2p_peer:peer()} | {error, term()}.
fetch_peer(ID, Store) ->
    case bitcask:get(Store, ID) of
        {ok, Bin} -> {ok, libp2p_peer:decode(Bin)};
        not_found -> {error, not_found};
        {error, _Error} -> error(error)
    end.

-spec fetch_peers(reference()) -> [libp2p_peer:peer()].
fetch_peers(Store) ->
    Result = bitcask:fold(Store, fun(_, Bin, Acc) ->
                                         [libp2p_peer:decode(Bin) | Acc]
                                 end, []),
    lists:reverse(Result).

-spec store_peer(libp2p_peer:peer(), reference()) -> ok.
store_peer(Peer, Store) ->
    case bitcask:put(Store, libp2p_peer:address(Peer), libp2p_peer:encode(Peer)) of
        {error, Error} -> error(Error);
        ok -> ok
    end.

-spec group_create(atom()) -> atom().
group_create(SwarmName) ->
    Name = list_to_atom(filename:join(SwarmName, peerbook)),
    ok = pg2:create(Name),
    Name.


notify_peers(Pids, ExcludePid, PeerList) ->
    [Pid ! {new_peers, PeerList} || Pid <- Pids, Pid /= ExcludePid].

group_notify_peers(Group, ExcludePid, PeerList) ->
    notify_peers(pg2:get_members(Group), ExcludePid, PeerList).

group_join(Group, Pid) ->
    ok = pg2:join(Group, Pid),
    ok.
