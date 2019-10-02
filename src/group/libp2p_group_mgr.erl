-module(libp2p_group_mgr).

-behaviour(gen_server).

%% API
-export([
         start_link/2,
         mgr/1,
         add_group/4,
         remove_group/2,
         force_gc/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         tid :: term(),
         group_deletion_predicate :: function(),
         storage_dir :: string()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(TID, Predicate) ->
    gen_server:start_link(?MODULE, [TID, Predicate], []).

mgr(TID) ->
    ets:lookup_element(TID, ?SERVER, 2).

%% these are a simple wrapper around swarm add group to prevent races
add_group(Mgr, GroupID, Module, Args) ->
    gen_server:call(Mgr, {add_group, GroupID, Module, Args}, infinity).

remove_group(Mgr, GroupID) ->
    gen_server:call(Mgr, {remove_group, GroupID}, infinity).

%% not implemented
force_gc(Mgr) ->
    gen_server:call(Mgr, force_gc, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([TID, Predicate]) ->
    _ = ets:insert(TID, {?SERVER, self()}),
    erlang:send_after(timer:seconds(30), self(), gc_tick),
    Dir = libp2p_config:swarm_dir(TID, [groups]),
    lager:debug("groups dir ~p", [Dir]),
    {ok, #state{tid  = TID,
                group_deletion_predicate = Predicate,
                storage_dir = Dir}}.

handle_call({add_group, GroupID, Module, Args}, _From,
            #state{tid = TID} = State) ->
    Reply =
        case libp2p_config:lookup_group(TID, GroupID) of
            {ok, Pid} ->
                lager:info("trying to add running group: ~p", [GroupID]),
                {ok, Pid};
            false ->
                lager:info("newly starting group: ~p", [GroupID]),
                GroupSup = libp2p_swarm_group_sup:sup(TID),
                ChildSpec = #{ id => GroupID,
                               start => {Module, start_link, [TID, GroupID, Args]},
                               restart => transient,
                               shutdown => 5000,
                               type => supervisor },
                case supervisor:start_child(GroupSup, ChildSpec) of
                    {error, Error} -> {error, Error};
                    {ok, GroupPid} ->
                        libp2p_config:insert_group(TID, GroupID, GroupPid),
                        {ok, GroupPid}
                end
        end,
    {reply, Reply, State};
handle_call({remove_group, GroupID}, _From, #state{tid = TID} = State) ->
    case libp2p_config:lookup_group(TID, GroupID) of
        {ok, _Pid} ->
            lager:info("removing group ~p", [GroupID]),
            GroupSup = libp2p_swarm_group_sup:sup(TID),
            _ = supervisor:terminate_child(GroupSup, GroupID),
            _ = supervisor:delete_child(GroupSup, GroupID),
            _ = libp2p_config:remove_group(TID, GroupID);
        false ->
            lager:warning("removing missing group ~p", [GroupID])
    end,
    {reply, ok, State};
handle_call(force_gc, _From, #state{group_deletion_predicate = Predicate,
                                    storage_dir = Dir} = State) ->
    lager:info("forcing gc"),
    Reply = gc(Predicate, Dir),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    {noreply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info(gc_tick, #state{group_deletion_predicate = Predicate,
                            storage_dir = Dir} = State) ->
    gc(Predicate, Dir),
    Timeout = application:get_env(libp2p, group_gc_tick, timer:seconds(30)),
    erlang:send_after(Timeout, self(), gc_tick),
    {noreply, State};
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

gc(_Predicate, "") ->
    lager:debug("no dir"),
    ok;
gc(Predicate, Dir) ->
    %% fetch all directories in Dir
    case file:list_dir(Dir) of
        {ok, Groups} ->
            %% filter using predicate
            Dels = lists:filter(Predicate, Groups),
            lager:debug("groups ~p dels ~p", [Groups, Dels]),
            %% delete.
            lists:foreach(fun(Grp) -> rm_rf(Dir ++ "/" ++ Grp) end, Dels);
        _ ->
            ok
    end,
    ok.


-spec rm_rf(file:filename()) -> ok.
rm_rf(Dir) ->
    lager:debug("deleting dir: ~p", [Dir]),
    Paths = filelib:wildcard(Dir ++ "/**"),
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
    ok = lists:foreach(fun file:delete/1, Files),
    Sorted = lists:reverse(lists:sort(Dirs)),
    ok = lists:foreach(fun file:del_dir/1, Sorted),
    file:del_dir(Dir).
