%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p NAT Statem ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_nat_statem).

-behavior(gen_statem).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
    ,ok/1
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1
    ,code_change/3
    ,callback_mode/0
    ,terminate/3
]).

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    enabled/3
]).

-record(data, {
    tid :: ets:tab() | undefined
    ,cache :: pid() | undefined
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

ok(TID) ->
    case get_nat_statem(TID) of
        {ok, Pid} ->
            gen_server:call(Pid, ok);
        {error, _}=Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% gen_statem Function Definitions
%% ------------------------------------------------------------------
init([TID]=_Args) ->
    lager:info("init with ~p", [_Args]),
    Cache = libp2p_swarm:cache(TID),
    true = libp2p_config:insert_nat(TID, self()),
    {ok, enabled, #data{tid=TID, cache=Cache}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

callback_mode() -> state_functions.

terminate(_Reason, _State, #data{tid=TID}) ->
    true = libp2p_config:remove_nat(TID),
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------

enabled(Type, Content, State) ->
    handle_event(Type, Content, State).

handle_event({call, From}, ok, Data) ->
    Reply = [{reply, From, ok}],
    {keep_state, Data, Reply};
handle_event(_Type, _Content, State) ->
    lager:warning("got unhandled msg ~p ~p", [_Type, _Content]),
    {keep_state, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_nat_statem(ets:tab()) -> {ok, pid()} | {error, any()}.
get_nat_statem(TID) ->
    case libp2p_config:lookup_nat(TID) of
        false -> {error, no_nat_statem};
        {ok, _Pid}=R -> R
    end.
