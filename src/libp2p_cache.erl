%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Cache ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_cache).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
    ,insert/3
    ,lookup/2, lookup/3
    ,delete/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1
    ,handle_call/3
    ,handle_cast/2
    ,handle_info/2
    ,terminate/2
    ,code_change/3
]).

-record(state, {
    dets :: dets:tab_name()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, [Args], []).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec insert(pid(), any(), any()) -> ok | {error, any()}.
insert(Pid, Key, Value) ->
    gen_server:call(Pid, {insert, Key, Value}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec lookup(pid(), any()) -> undefined | any().
lookup(Pid, Key) ->
    lookup(Pid, Key, undefined).

-spec lookup(pid(), any(), any()) -> undefined | any().
lookup(Pid, Key, Default) ->
    gen_server:call(Pid, {lookup, Key, Default}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec delete(pid(), any()) -> ok | {error, any()}.
delete(Pid, Key) ->
    gen_server:call(Pid, {delete, Key}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_sup:register_cache(TID),
    SwarmName = libp2p_swarm:name(TID),
    DataDir = libp2p_config:base_dir(TID),
    Opts = [{file, filename:join([DataDir, SwarmName, "cache.dets"])}],
    {ok, Name} = dets:open_file(SwarmName, Opts),
    {ok, #state{dets=Name}}.

handle_call({insert, Key, Value}, _From, #state{dets=Name}=State) ->
    Result = dets:insert(Name, {Key, Value}),
    {reply, Result, State};
handle_call({lookup, Key, Default}, _From, #state{dets=Name}=State) ->
    Result = case dets:lookup(Name, Key) of
        [] -> Default;
        [{Key, Value}] -> Value;
        [{Key, Value}|_]-> Value
    end,
    {reply, Result, State};
handle_call({delete, Key}, _From, #state{dets=Name}=State) ->
    Result = dets:delete(Name, Key),
    {reply, Result, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{dets=Name}) ->
    ok = dets:close(Name),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.