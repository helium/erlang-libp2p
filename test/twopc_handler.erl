-module(twopc_handler).

-behavior(relcast).

-export([init/1,
         handle_message/3,
         handle_command/2,
         callback_message/3,
         serialize/1, deserialize/1,
         restore/2]).

-record(state,
        {
         m = m,
         me,
         v = v,
         val = 0,
         p = p,
         prep_val,
         r = r,
         restarts = 0,
         l = '------',
         votes = #{},
         commits = #{},
         prop_val,
         from,
         leader,
         total
        }).

init([Members, true, _]) ->
    {ok, #state{leader = self, me = 1, total = length(Members)}};
init([_Members, MyIdx, LeaderIdx]) ->
    lager:info("member ~p init", [MyIdx]),
    {ok, #state{leader = LeaderIdx, me = MyIdx}}.

handle_message(Msg0, Index, State=#state{prop_val = Proposal,
                                         votes = Votes,
                                         total = Total,
                                         commits = Commits,
                                         from = From,
                                         leader = self}) ->
    Msg = binary_to_term(Msg0),
    case Msg of
        {prep_ack, PrepAckVal} when PrepAckVal == Proposal ->
            lager:info("leader ~p got message from ~p: ~p", [self(), Index, Msg]),
            Response =
                case enough_votes(Index, Total, Proposal, Votes) of
                    {true, Votes1} ->
                        %%lager:info("accepted! ~p", [Proposal]),
                        [{multicast, term_to_binary({commit, Proposal})}];
                    {false, Votes1} ->
                        %%lager:info("not accepted yet! ~p", [Proposal]),
                        []
                end,
            {State#state{votes = maps:remove(Proposal - 1, Votes1)}, Response};
        {commit_ack, CommitAckVal} when CommitAckVal == Proposal ->
            lager:info("leader ~p got message from ~p: ~p", [self(), Index, Msg]),
            case enough_votes(Index, Total, Proposal, Commits) of
                {true, Commits1} ->
                    %%lager:info("done! ~p", [Proposal]),
                    From ! {finished, Proposal},
                    {State#state{val = Proposal,
                                 commits = maps:remove(Proposal - 5, Commits1)}, []};
                {false, Commits1} ->
                    %%lager:info("not done! ~p", [Proposal]),
                    {State#state{commits = Commits1}, []}
            end;
        %% ignore self messages
        {prepare, _} ->
            ignore;
        {commit, _} ->
            ignore;
        Unexpected ->
            lager:info("leader got unexpected message from ~p: ~p", [Index, Unexpected]),
            ignore
    end;
handle_message(Msg0, _Index, State=#state{val = Val,
                                          prep_val = PrepVal,
                                          leader = Leader}) ->
    Msg = binary_to_term(Msg0),
    lager:info("~p ~p got message from ~p: ~p", [State#state.me, self(), _Index, Msg]),
    case Msg of
        {prepare, NewPrepVal} ->
            {State#state{prep_val = NewPrepVal},
             [{unicast, Leader, term_to_binary({prep_ack, NewPrepVal})}]};
        {commit, CommitVal} when CommitVal == PrepVal ->
            {State#state{val = CommitVal, prep_val = undefined},
             [{unicast, Leader, term_to_binary({commit_ack, CommitVal})}]};
        {commit, CommitVal} when CommitVal =< Val -> % late resend?
            ignore
    end.

handle_command({set_val, From, Val}, #state{leader = self} = State) ->
    lager:info("set val ~p", [Val]),
    {reply, {ok, Val}, [{multicast, term_to_binary({prepare, Val})}],
     State#state{prop_val = Val, from = From}};
handle_command({set_val, Val}, #state{} = State) ->
    lager:info("bad set val ~p", [Val]),
    {reply, {error, not_leader}, [], State};
handle_command(stop, #state{} = State) ->
    lager:info("stopping ~p", [State]),
    {reply, ok, [{stop, 1}], State}.

callback_message(_, _, _) ->
    none.

serialize(State) ->
    lager:info("serialize ~p", [State]),
    term_to_binary(State).

deserialize(BinState) ->
    State = binary_to_term(BinState),
    lager:info("deserialize ~p", [State]),
    State.

restore(OldState = #state{restarts = Restarts}, _NewState) ->
    lager:info("starting ~p ~p", [OldState, _NewState]),
    {ok, OldState#state{restarts = Restarts + 1}}.

enough_votes(I, T, N, Map) ->
    %% lager:info("~p ~p ~p ~p", [I, T, N, Map]),
    List = maps:get(N, Map, []),
    L2 = [I | List],
    case lists:member(I, List) of
        true ->
            %% error({double_vote, Map, idx, I, prop, N});
            {length(List) == (T - 1), Map};
        false ->
            {length(L2) == (T - 1), Map#{N => L2}}
    end.
