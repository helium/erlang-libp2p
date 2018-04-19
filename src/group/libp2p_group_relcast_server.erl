-module(libp2p_group_relcast_server).

-behaviour(gen_server).

%% API
-export([start_link/3]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state,
       { sup :: pid(),
         tid :: ets:tab(),
         client_specs :: [libp2p_group:stream_client_spec()],
         targets :: [string()],
         workers=[] :: [pid()]
       }).

%% gen_server
%%

start_link(Addrs, Sup, TID) ->
    gen_server:start_link(?MODULE, [Addrs, Sup, TID], []).

init([Addrs, Sup, TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_group_agent(TID),
    Opts = libp2p_swarm:opts(TID, []),
    ClientSpecs = libp2p_group_relcast:get_opt(Opts, stream_clients, []),
    TargetAddrs = lists:map(fun mk_multiaddr/1, Addrs),
    self() ! {start_workers, length(TargetAddrs)},
    {ok, #state{sup=Sup, tid=TID, client_specs=ClientSpecs, targets=TargetAddrs}}.

handle_call(sessions, _From, State=#state{targets=Targets, workers=Workers}) ->
    {reply, lists:zip(Targets, Workers), State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call: ~p", [Msg]),
    {reply, ok, State}.

handle_cast({request_target, Index, WorkerPid}, State=#state{targets=Targets}) ->
    libp2p_group_worker:assign_target(WorkerPid, lists:nth(Index, Targets)),
    {noreply, State};
handle_cast({send, _Bin}, State=#state{}) ->
    %% TODO: This is the interesting part
    {noreply, State};
handle_cast({send_result, _Ref, _Reason}, State=#state{}) ->
    {noreply, State};
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({start_workers, Count}, State=#state{sup=Sup}) ->
    WorkerSup = libp2p_group_gossip_sup:workers(Sup),
    Workers = [start_child(WorkerSup, I, State) || I <- lists:seq(1, Count)],
    {noreply, State#state{workers=Workers}};
handle_info(Msg, State) ->
    lager:warning("Unhandled cast: ~p", [Msg]),
    {noreply, State}.




%% Internal
%%

-spec start_child(pid(), integer(), #state{}) -> pid().
start_child(Sup, Index, #state{tid=TID, client_specs=ClientSpecs}) ->
    ChildSpec = #{ id => make_ref(),
                   start => {libp2p_group_worker, start_link, [Index, ClientSpecs, self(), TID]},
                   restart => permanent
                 },
    {ok, WorkerPid} = supervisor:start_child(Sup, ChildSpec),
    WorkerPid.

mk_multiaddr(Addr) when is_binary(Addr) ->
    lists:flatten(["/p2p/", libp2p_crypto:address_to_b58(Addr)]);
mk_multiaddr(Value) ->
    Value.
