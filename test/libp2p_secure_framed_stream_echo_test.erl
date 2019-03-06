-module(libp2p_secure_framed_stream_echo_test).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    client/2,
    server/4
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-record(state, {
    echo
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, _Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, Args).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, [_, Echo|_]) ->
    {ok, #state{echo=Echo}};
init(client, _Conn, [Echo|_]) ->
    {ok, #state{echo=Echo}}.

handle_data(Type, Data, #state{echo=Echo}=State) ->
    Echo ! {echo, Type, Data},
    {noreply, State}.

handle_info(_Type, {send, Data}, State) ->
    {noreply, State, Data};
handle_info(_Type, _Msg, State) ->
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
