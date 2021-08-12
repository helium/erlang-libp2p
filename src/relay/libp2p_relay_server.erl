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
    relay/1,
    stop/1, replace/2,
    negotiated/2
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
    address :: string() | undefined,
    stream :: pid() | undefined,
    retrying = make_ref() :: reference(),
    banlist = [] :: list()
}).

-type state() :: #state{}.

-define(FLAP_LIMIT, 3).
-define(BANLIST_TIMEOUT, timer:minutes(5)).
-define(BANLIST_LIMIT, 20).
-define(MAX_RELAY_DURATION, timer:minutes(90)).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(TID) ->
    gen_server:start_link(reg_name(TID), ?MODULE, [TID], [{hibernate_after, 5000}]).

reg_name(TID)->
    {local,libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

-spec relay(pid()) -> ok | {error, any()}.
relay(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:cast(Pid, init_relay);
        {error, _}=Error ->
            Error
    end.

-spec stop(pid()) -> ok | {error, any()}.
stop(Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:cast(Pid, stop_relay);
        {error, _}=Error ->
            Error
    end.

-spec replace(string(), pid()) -> ok | {error, any()}.
replace(Address, Swarm) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            Pid ! {replace_relay, Address};
        {error, _}=Error ->
            Error
    end.

-spec negotiated(pid(), string()) -> ok | {error, any()}.
negotiated(Swarm, Address) ->
    case get_relay_server(Swarm) of
        {ok, Pid} ->
            gen_server:call(Pid, {negotiated, Address, self()});
        {error, _}=Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([TID]) ->
    %% remove any prior relay addresses we somehow leaked
    lists:foreach(fun(Addr) ->
                          case libp2p_transport_relay:match_addr(Addr,TID) of
                              {ok, _} ->
                                  libp2p_config:remove_listener(TID, Addr);
                              _ ->
                                  ok
                          end
                  end, libp2p_config:listen_addrs(TID)),
    lager:info("~p init with ~p", [?MODULE, TID]),
    true = libp2p_config:insert_relay(TID, self()),
    {ok, #state{tid=TID}}.

handle_call({negotiated, Address, Pid}, _From, #state{tid=TID, stream=Pid}=State) when is_pid(Pid) ->
    true = libp2p_config:insert_listener(TID, [Address], Pid),
    lager:info("inserting new listener ~p, ~p, ~p", [TID, Address, Pid]),
    %% to ensure we don't get black-hole routed by a naughty relay, schedule a max-age we keep this relay around
    %% before trying to obtain a new one
    erlang:send_after(?MAX_RELAY_DURATION, self(), {replace_relay, Address}),
    {reply, ok, State#state{address=Address}};
handle_call({negotiated, _Address, _Pid}, _From, #state{stream=undefined}=State) ->
    lager:error("cannot insert ~p listener unknown stream (~p)", [_Address, _Pid]),
    {reply, {error, unknown_pid}, State};
handle_call({negotiated, _Address, Pid1}, _From, #state{stream=Pid2}=State) ->
    lager:error("cannot insert ~p listener wrong stream ~p (~p)", [_Address, Pid1, Pid2]),
    {reply, {error, wrong_pid}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(stop_relay, #state{stream=Pid, address=Address, tid=TID}=State) when is_pid(Pid) ->
    lager:warning("relay was asked to be stopped ~p ~p", [Pid, Address]),
    _ = libp2p_config:remove_listener(TID, Address),
    catch libp2p_framed_stream:close(Pid),
    %% don't use the banlist here, we likely disconnected because we negotiated a NAT punch
    {noreply, State#state{stream=undefined, address=undefined}};
handle_cast(stop_relay, State) ->
    %% nothing to do as we're not running
    %% except cancel the retrying timer
    erlang:cancel_timer(State#state.retrying),
    %% leave the timer ref in the state, it's fine
    {noreply, State};
handle_cast(init_relay, #state{stream = undefined} = State) ->
    case init_relay(State) of
        {ok, Pid, Address} ->
            _ = erlang:monitor(process, Pid),
            lager:info("relay started successfully with ~p", [Address]),
            {noreply, State#state{stream=Pid}};
        {error, Reason, Address} ->
            lager:warning("could not initiate relay with ~p ~p", [Address, Reason]),
            {noreply, retry(banlist(Address, State))};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {noreply, retry(State)}
    end;
handle_cast(init_relay,  #state{stream=Pid}=State) when is_pid(Pid) ->
    lager:info("requested to init relay but we already have one @ ~p", [Pid]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(retry, #state{stream=undefined}=State) ->
    case init_relay(State) of
        {ok, Pid, Address} ->
            _ = erlang:monitor(process, Pid),
            lager:info("relay started successfully with ~p", [Address]),
            {noreply, State#state{stream=Pid}};
        {error, Reason, Address} ->
            lager:warning("could not initiate relay with ~p ~p", [Address, Reason]),
            {noreply, retry(banlist(Address, State))};
        _Error ->
            lager:warning("could not initiate relay ~p", [_Error]),
            {noreply, retry(State)}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{tid=TID, stream=Pid, address=Address}=State) ->
    lager:info("Relay session with address ~p closed with reason ~p", [Address, Reason]),
    _ = libp2p_config:remove_listener(TID, Address),
    %% add it to the banlist so we temporarily avoid trying to connect to it again
    {noreply, retry(banlist(Address, State#state{stream=undefined, address=undefined}))};
handle_info({replace_relay, Address}, #state{stream=Pid, address=Address, tid=TID}=State) when is_pid(Pid) ->
    lager:warning("relay was asked to be replaced ~p ~p", [Pid, Address]),
    _ = libp2p_config:remove_listener(TID, Address),
    catch libp2p_framed_stream:close(Pid),
    %% we likely disconnected from this relay specifically because of overload or max duration
    %% so avoid immediately re-connecting to it
    {noreply, retry(banlist(Address, State#state{stream=undefined, address=undefined}))};
handle_info({replace_relay, _OtherAddress}, State) ->
    %% nothing to do as we're not running
    {noreply, State};
handle_info({unbanlist, PeerAddr}, State=#state{banlist=Banlist}) ->
    {noreply, State#state{banlist=lists:delete(PeerAddr, Banlist)}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{tid=TID, stream=Pid, address=Address}) when is_pid(Pid) ->
    catch libp2p_framed_stream:close(Pid),
    true = libp2p_config:remove_relay(TID),
    %% remove listener is harmless if the address is undefined
    _ = libp2p_config:remove_listener(TID, Address),
    ok;
terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

retry(#state{retrying=OldTimer}=State) ->
    erlang:cancel_timer(OldTimer),
    TimeRef = erlang:send_after(2500, self(), retry),
    State#state{retrying=TimeRef}.

-spec get_relay_server(pid()) -> {ok, pid()} | {error, any()}.
get_relay_server(Swarm) ->
    try libp2p_swarm:tid(Swarm) of
        TID ->
            case libp2p_config:lookup_relay(TID) of
                false -> {error, no_relay};
                {ok, _Pid}=R -> R
            end
    catch
        What:Why ->
            lager:warning("fail to get relay server ~p/~p", [What, Why]),
            {error, swarm_down}
    end.

-spec init_relay(state()) ->
                        {ok, pid(), string()} | {error, retry} | {error, any(), string()} | ignore.
init_relay(#state{tid = TID, banlist = Banlist}) ->
    Swarm = libp2p_swarm:swarm(TID),
    SwarmPubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    Peerbook = libp2p_swarm:peerbook(Swarm),

    lager:debug("init relay for swarm ~p", [libp2p_swarm:name(Swarm)]),
    case libp2p_peerbook:random(Peerbook,[SwarmPubKeyBin | Banlist],
                                fun(P) ->
                                        libp2p_peer:has_public_ip(P) andalso
                                            not libp2p_peer:is_stale(P, timer:minutes(45))
                                end, 100) of
        {Address, _Peer} ->
            Address1 = libp2p_crypto:pubkey_bin_to_p2p(Address),
            lager:info("initiating relay with peer ~p", [Address1]),
            case libp2p_relay:dial_framed_stream(Swarm, Address1, []) of
                {ok, Pid} ->
                    {ok, Pid, Address1};
                {error, Reason} ->
                    {error, Reason, Address1}
            end;
        false ->
            {error, retry}
    end.

-spec banlist(undefined | string(), #state{}) -> #state{}.
banlist(undefined, State) ->
    %% relay failed before we found out the address
    State;
banlist(Address, State=#state{banlist=Banlist}) ->
    PeerAddr = case libp2p_relay:is_p2p_circuit(Address) of
                   true ->
                       {ok, {RAddress, _SAddress}} = libp2p_relay:p2p_circuit(Address),
                       libp2p_crypto:p2p_to_pubkey_bin(RAddress);
                   false ->
                       libp2p_crypto:p2p_to_pubkey_bin(Address)
               end,
    case lists:member(PeerAddr, Banlist) of
        true ->
            State;
        false ->
            erlang:send_after(?BANLIST_TIMEOUT, self(), {unbanlist, PeerAddr}),
            BanList1 =
                case length(Banlist) >= ?BANLIST_LIMIT of
                    true ->
                        [_H | T] = Banlist,
                        T ++ [PeerAddr];
                    false ->
                        Banlist ++ [PeerAddr]
                end,
            State#state{banlist=BanList1}
    end.
