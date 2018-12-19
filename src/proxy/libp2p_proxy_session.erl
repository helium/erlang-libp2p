%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Proxy Session ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_session).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_server/4,
    start_link/1
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
    type :: client | server,
    connection :: libp2p_connection:connection(),
    path :: string(),
    tid :: ets:tab()
}).

-spec start_server(libp2p_connection:connection(), string(), ets:tab(), []) -> no_return().
start_server(Connection, Path, TID, []) ->
    %% In libp2p_swarm, the server takes over the calling process
    %% since it's fired of synchronously by a multistream. Since ranch
    %% already assigned the controlling process, there is no need to
    %% wait for a shoot message
    {ok, State} = init([server, Connection, Path, TID]),
    gen_server:enter_loop(?MODULE, [], State).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Type, Connection, Path, TID]=Args) ->
    lager:info("~p init with ~p", [?MODULE, Args]),
    case Type of
        client -> ok;
        server -> self() ! transfer_socket
    end,
    {ok, #state{type=Type, connection=Connection, path=Path, tid=TID}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(transfer_socket, #state{type=server, connection=Connection, path=Path, tid=TID}=State) ->
    lager:info("doing socket transfer"),
    <<"/", ID0/binary>> = erlang:list_to_binary(Path),
    ID1 = base58:base58_to_binary(erlang:binary_to_list(ID0)),
    ok = libp2p_proxy_server:connection(TID, Connection, ID1),
    {noreply, State};
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
