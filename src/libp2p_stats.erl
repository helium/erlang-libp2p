-module(libp2p_stats).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         report/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         stats = #{} :: #{atom() => non_neg_integer()}
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

report(Source, Bytes) ->
    gen_server:cast(?MODULE, {report, Source, Bytes}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    erlang:send_after(timer:seconds(10), self(), tick),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({report, Source, Bytes}, #state{stats = Stats} = State) ->
    Stats1 = update_stats(Source, Bytes, Stats),
    {noreply, State#state{stats = Stats1}};
handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info(tick, #state{stats = Stats} = State) ->
    lager:info("tick stats ~p", [Stats]),
    erlang:send_after(timer:seconds(10), self(), tick),
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

update_stats(Source, Size, Stats) ->
    case maps:find(Source, Stats) of
        error ->
            Stats#{Source => Size};
        {ok, Old} ->
            Stats#{Source => Old + Size}
    end.
