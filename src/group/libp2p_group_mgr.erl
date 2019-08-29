-module(libp2p_group_mgr).

-behaviour(gen_server).

%% API
-export([
         start_link/1,
         mgr/1,
         add_group/5,
         remove_group/3,
         force_gc/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(TID) ->
    gen_server:start_link(?MODULE, [TID], []).

mgr(TID) ->
    ets:lookup_element(TID, ?SERVER, 2).

%% these are a simple wrapper around swarm add group to prevent races
add_group(Mgr, TID, GroupID, Module, Args) ->
    gen_server:call(Mgr, {add_group, TID, GroupID, Module, Args}, infinity).

remove_group(Mgr, TID, GroupID) ->
    gen_server:call(Mgr, {remove_group, TID, GroupID}, infinity).

%% not implemented
force_gc(Mgr) ->
    gen_server:call(Mgr, add_group, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([TID]) ->
    _ = ets:insert(TID, {?SERVER, self()}),
    {ok, #state{}}.

handle_call({add_group, TID, GroupID, Module, Args}, _From, State) ->
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
handle_call({remove_group, TID, GroupID}, _From, State) ->
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
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

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
