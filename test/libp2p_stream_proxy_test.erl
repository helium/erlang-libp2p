-module(libp2p_stream_proxy_test).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    client/2
    ,server/4
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3
    ,handle_data/3
    ,handle_info/3
]).

-record(state, {
    echo :: pid()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, _Args) ->
    lager:warning("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, server]),
    {ok, #state{}};
init(client, _Conn, Args) ->
    lager:warning("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, client]),
    Echo = proplists:get_value(echo, Args),
    {ok, #state{echo=Echo}}.

handle_data(server, Data, State) ->
    lager:warning("[~p:~p:~p] SERVER ~p ECHOING ~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data]),
    {noreply, State, Data};
handle_data(client, Data, #state{echo=Echo}=State) ->
    lager:warning("[~p:~p:~p] CLIENT ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data]),
    Echo ! {echo, Data},
    {noreply, State}.

handle_info(server, Msg, State) ->
    lager:warning("[~p:~p:~p] SERVER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Msg]),
    {noreply, State, Msg};
handle_info(client, Msg, State) ->
    lager:warning("[~p:~p:~p] CLIENT ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Msg]),
    {noreply, State, Msg}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
