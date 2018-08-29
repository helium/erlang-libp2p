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
    start/1
    ,register/4
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
    started/3
    ,active/3
]).

-record(data, {
    port :: integer() | undefined
    ,lease :: integer() | undefined
    ,since :: integer() | undefined
}).

-define(CACHE_KEY, nat_lease).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start(Args) ->
    gen_statem:start(?MODULE, Args, []).

register(Pid, Port, Lease, Since) ->
    gen_server:cast(Pid, {register, Port, Lease, Since}).

%% ------------------------------------------------------------------
%% gen_statem Function Definitions
%% ------------------------------------------------------------------
init([Pid]=_Args) ->
    lager:info("init with ~p", [_Args]),
    true = erlang:link(Pid),
    {ok, started, #data{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

callback_mode() -> state_functions.

terminate(_Reason, _State, _Data) ->
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------

started(cast, {register, Port, Lease, Since}, Data) ->
    case Lease =:= 0 of
        false -> ok;
        true ->
            _ = erlang:send_after(Lease-10, self(), renew)
    end,
    {next_state, active, Data#data{port=Port, lease=Lease, since=Since}};
started(Type, Content, Data) ->
    handle_event(Type, Content, Data).

active(info, renew, #data{port=Port}=Data) ->
    case libp2p_nat:add_port_mapping(Port) of
        {ok, _, Lease, Since} ->
            _ = erlang:send_after(Lease-10, self(), renew),
            {keep_state, Data#data{lease=Lease, since=Since}};
        {error, _Reason} ->
            lager:warning("failed to renew lease for port ~p: ~p", [Port, _Reason]),
            {stop, renew_failed}
    end;
active(Type, Content, Data) ->
    handle_event(Type, Content, Data).

handle_event(_Type, _Content, Data) ->
    lager:warning("got unhandled msg ~p ~p", [_Type, _Content]),
    {keep_state, Data}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
