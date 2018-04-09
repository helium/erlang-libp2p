%%%-------------------------------------------------------------------
%%% @author Marc Nijdam <marc@helium.com>
%%% @copyright (C) 2018, Helium
%%% @doc
%%%
%%% @end
%%% Created :  9 Apr 2018 by Marc Nijdam <marc@helium.com>
%%%-------------------------------------------------------------------
-module(libp2p_group_gossip_worker).

-behaviour(gen_statem).

%% API
-export([start_link/0]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([state_name/3]).

-define(SERVER, ?MODULE).

-record(data, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link() ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Define the callback_mode() for this callback module.
%% @end
%%--------------------------------------------------------------------
-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> state_functions.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) ->
                  gen_statem:init_result(atom()).
init([]) ->
    process_flag(trap_exit, true),
    {ok, state_name, #data{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one function like this for each state name.
%% Whenever a gen_statem receives an event, the function
%% with the name of the current state (StateName)
%% is called to handle the event.
%% @end
%%--------------------------------------------------------------------
-spec state_name('enter',
                 OldState :: atom(),
                 Data :: term()) ->
                        gen_statem:state_enter_result('state_name');
                (gen_statem:event_type(),
                 Msg :: term(),
                 Data :: term()) ->
                        gen_statem:event_handler_result(atom()).
state_name({call,Caller}, _Msg, Data) ->
    {next_state, state_name, Data, [{reply,Caller,ok}]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: term(), State :: term(), Data :: term()) ->
                       any().
terminate(_Reason, _State, _Data) ->
    void.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(
        OldVsn :: term() | {down,term()},
        State :: term(), Data :: term(), Extra :: term()) ->
                         {ok, NewState :: term(), NewData :: term()} |
                         (Reason :: term()).
code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-module(libp2p_group_gossip_worker).




%% -behavior(gen_server).

%% -export([start_link/4, init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% -type client_spec() :: {Path::string(), {Module::atom(), Args::[any()]}}.

%% -record(state,
%%         { tid :: ets:tab(),
%%           kind :: atom(),
%%           target=undefined :: undefined | string(),
%%           client_specs :: [client_spec()],
%%           server :: pid(),
%%           monitor :: reference()
%%         }).

%% start_link(Kind, ClientSpecs, Server, TID) ->
%%     gen_server:start_link(?MODULE, [Kind, ClientSpecs, Server, TID], []).

%% init([Kind, ClientSpecs, TID]) ->
%%     erlang:process_flag(trap_exit, true),
%%     self() ! connect,
%%     {ok, #state{tid=TID, kind=Kind, client_specs=ClientSpecs}}.

%% handle_call(Msg, _From, #state{}) ->
%%     lager:warning("Unhandled call ~p", [Msg]).

%% handle_cast(Msg, #state{}) ->
%%     lager:warning("Unhandled cast ~p", [Msg]).


%% handle_info({'DOWN', Monitor, process, _, _}, State=#state{monitor=Monitor}) ->
%%     erlang:send_after(1000, self(), connect),
%%     {noreply, State};
%% handle_info(connect, State=#state{kind=Kind, server=Server, target=undefined}) ->
%%     case libp2p_group_gossip_server:assign_target(Server, Kind) of
%%         undefined ->
%%             erlang:send_after(5000, self(), connect),
%%             {noreply, State};
%%         Target ->
%%             self() ! connect, Target,
%%             {noreply, State#state{target=Target}}
%%     end;
%% handle_info(connect, State=#state{tid=TID, client_specs=ClientSpecs, target=Target}) ->
%%     case libp2p_transport:connect_to(Target, [], 5000, TID) of
%%         {error, _Reason} ->
%%             erlang:send_after(1000, self(), {connect, Target}),
%%             {noreply, State};
%%         {ok, ConnAddr, SessionPid} ->
%%             libp2p_swarm:register_session(libp2p_swarm:swarm(TID), ConnAddr, SessionPid),
%%             Monitor = erlang:add_monitor(process, SessionPid),
%%             lists:foreach(fun({Path, {M, A}}) ->
%%                                   libp2p_session:start_client_framed_stream(Path, SessionPid, M, A)
%%                           end, ClientSpecs),
%%             State#state{monitor=Monitor}
%%     end.
