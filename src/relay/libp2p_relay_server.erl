%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Relay Server ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_relay_server).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    allowed/2
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
    tid :: ets:tab() | undefined,
    limit :: integer(),
    size = 0 :: integer()
}).

% -type state() :: #state{}.


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec allowed(pid(), pid()) -> ok | {error, any()}.
allowed(Swarm, StreamPid) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:call(Pid, {allowed, StreamPid});
        {error, _}=Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID, Limit]=_Args) ->
    true = libp2p_config:insert_relay_server(TID, self()),
    lager:info("~p init with ~p", [?MODULE, _Args]),
    {ok, #state{tid=TID, limit=Limit}}.

handle_call({allowed, Pid}, _From, #state{limit=Limit, size=Size}=State) ->
    case Size+1 > Limit of
        true ->
            {reply, {error, relay_limit_exceeded}, State};
        false ->
            _Ref = erlang:monitor(process, Pid),
            {reply, ok, State#state{size=Size+1}}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, _Pid, _Reason}, #state{size=Size}=State) ->
    {noreply, State#state{size=Size-1}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_relay_server(pid()) -> {ok, pid()} | {error, any()}.
get_relay_server(Swarm) ->
    try libp2p_swarm:tid(Swarm) of
        TID ->
            case libp2p_config:lookup_relay_server(TID) of
                false -> {error, no_relay_server};
                {ok, _Pid}=R -> R
            end
    catch
        What:Why ->
            lager:warning("fail to get relay server ~p/~p", [What, Why]),
            {error, swarm_down}
    end.