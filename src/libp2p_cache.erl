%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Cache ==
%% Simple dets cache
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_cache).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    insert/3,
    lookup/2, lookup/3,
    delete/2
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    dets :: dets:tab_name()
}).

-define(MIGRATE, #{
    tcp_listen_addrs => tcp_local_listen_addrs
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

%% @hidden
start_link(Args) ->
    gen_server:start_link(?MODULE, [Args], []).

%%--------------------------------------------------------------------
%% @doc
%% Insert key, value in cache
%% @end
%%--------------------------------------------------------------------
-spec insert(pid(), any(), any()) -> ok | {error, any()}.
insert(Pid, Key, Value) ->
    gen_server:call(Pid, {insert, Key, Value}).

%%--------------------------------------------------------------------
%% @doc
%% Lookup key in cache (default to `undefined')
%% @end
%%--------------------------------------------------------------------
-spec lookup(pid(), any()) -> undefined | any().
lookup(Pid, Key) ->
    lookup(Pid, Key, undefined).

%%--------------------------------------------------------------------
%% @doc
%% Lookup key in cache with default value
%% @end
%%--------------------------------------------------------------------
-spec lookup(pid(), any(), any()) -> undefined | any().
lookup(Pid, Key, Default) ->
    gen_server:call(Pid, {lookup, Key, Default}).

%%--------------------------------------------------------------------
%% @doc
%% Delete key in cache
%% @end
%%--------------------------------------------------------------------
-spec delete(pid(), any()) -> ok | {error, any()}.
delete(Pid, Key) ->
    gen_server:call(Pid, {delete, Key}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

%% @hidden
init([TID]) ->
    erlang:process_flag(trap_exit, true),
    libp2p_swarm_auxiliary_sup:register_cache(TID),
    SwarmName = libp2p_swarm:name(TID),
    DataDir = libp2p_config:base_dir(TID),
    Opts = [{file, filename:join([DataDir, SwarmName, "cache.dets"])}],
    {ok, Dets} = dets:open_file(SwarmName, Opts),
    _ = migrate(Dets),
    {ok, #state{dets=Dets}}.

%% @hidden
handle_call({insert, Key, Value}, _From, #state{dets=Dets}=State) ->
    Result = dets:insert(Dets, {Key, Value}),
    {reply, Result, State};
handle_call({lookup, Key, Default}, _From, #state{dets=Dets}=State) ->
    Result = case dets:lookup(Dets, Key) of
        [] -> Default;
        [{Key, Value}] -> Value;
        [{Key, Value}|_]-> Value
    end,
    {reply, Result, State};
handle_call({delete, Key}, _From, #state{dets=Dets}=State) ->
    Result = dets:delete(Dets, Key),
    {reply, Result, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

%% @hidden
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

%% @hidden
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @hidden
terminate(_Reason, #state{dets=Name}) ->
    ok = dets:close(Name),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

migrate(Dets) ->
    maps:fold(
        fun(Key, undefined, _) ->
            dets:delete(Dets, Key);
        (Key0, Key1, _) ->
            case dets:lookup(Dets, Key0) of
                [] -> 
                    ok;
                [{Key0, Value}] -> 
                    dets:insert(Dets, {Key1, Value});
                [{Key0, Value}|_]-> 
                    dets:insert(Dets, {Key1, Value})
            end,
            dets:delete(Dets, Key0)
        end,
        ok,
        ?MIGRATE
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
