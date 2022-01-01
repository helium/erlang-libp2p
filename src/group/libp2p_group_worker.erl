-module(libp2p_group_worker).

-behaviour(gen_statem).
-behavior(libp2p_info).

-type stream_client_spec() :: {[Path::string()], {Module::atom(), Args::[any()]}}.
-export_type([stream_client_spec/0]).

%% API
-export([start_link/6, start_link/9,
         assign_target/2, clear_target/1,
         assign_stream/2, assign_stream/3, send/4, send_ack/3, close/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([targeting/3, connecting/3, connected/3, closing/3]).

%% libp2p_info
-export([info/1]).

-define(SERVER, ?MODULE).
-define(TRIGGER_TARGETING, {next_event, info, targeting_timeout}).
-define(TRIGGER_CONNECT_RETRY, {next_event, info, connect_retry_timeout}).
-define(MIN_CONNECT_RETRY_TIMEOUT, 5000).
-define(MAX_CONNECT_RETRY_TIMEOUT, 20000).
-define(CONNECT_RETRY_CANCEL_TIMEOUT, 10000).
-define(MIN_TARGETING_RETRY_TIMEOUT, 1000).
-define(MAX_TARGETING_RETRY_TIMEOUT, 10000).

-type target() :: {MAddr::string(), Spec::stream_client_spec()}.

-record(data,
        { ref :: reference(),
          tid :: ets:tab(),
          kind :: atom() | pos_integer(),
          group_id :: string(),
          dial_options = [] :: [any()],
          server :: pid(),
          %% Target information
          target={undefined, undefined} :: target() | {undefined, undefined},
          target_timer=undefined :: undefined | reference(),
          target_backoff :: backoff:backoff(),
          % Connect data
          connect_pid=undefined :: undefined | pid(),
          connect_retry_timer=undefined :: undefined | reference(),
          connect_retry_backoff :: backoff:backoff(),
          connect_retry_cancel_timer=undefined :: undefined | reference(),
          %% Stream we're managing
          stream_pid=undefined :: undefined | pid(),
          worker_path=undefined :: undefined | atom()
        }).

%% API

%% @doc Assign a target to a worker. This causes the worker to go back
%% to attempting to connect to the given target, dropping it's stream
%% if it has one. The target is passed as the a tuple consisting of
%% the crytpo address and the spec of the stream client to start once
%% the worker is connected to the target.
-spec assign_target(pid(), target()) -> ok.
assign_target(Pid, Target) ->
    gen_statem:cast(Pid, {assign_target, Target}).

%% @doc Clears the current target for the worker. The worker goes back
%% to target acquisition, after dropping it's streeam if it has one.
-spec clear_target(pid()) -> ok.
clear_target(Pid) ->
    gen_statem:cast(Pid, clear_target).

%% @doc Assigns the given stream to the worker. This does _not_ update
%% the target of the worker but moves the worker to the `connected'
%% state and uses it to send data.
-spec assign_stream(pid(), StreamPid::pid()) -> ok.
assign_stream(Pid, StreamPid) ->
    Pid ! {assign_stream, StreamPid},
    ok.

%% @doc Assigns the given stream to the worker. This does _not_ update
%% the target of the worker but moves the worker to the `connected'
%% state and uses it to send data.
%% This also updates the path of the given worker
-spec assign_stream(pid(), StreamPid::pid(), Path::string()) -> ok.
assign_stream(Pid, StreamPid, Path) ->
    Pid ! {assign_stream, StreamPid, Path},
    ok.

%% @doc Sends a given `Data' binary on it's stream asynchronously and if required encode the msg first. The given `Ref' is
%% used to indicate the send result to the server for the worker.
%%
%% @see libp2p_group_server:send_result/4
-spec send(pid(), term(), any(), boolean()) -> ok.
send(Pid, Ref, Data, MaybeEncode) ->
    gen_statem:cast(Pid, {send, Ref, Data, MaybeEncode}).


%% @doc Changes the group worker state to `closing' state. Closing
%% means that a newly assigned stream is still accepted but the worker
%% will not attempt to re-acquire a target or re-connect.
-spec close(pid()) -> ok.
close(Pid) ->
    Pid ! close,
    ok.

%% @doc Used as a convenience for groups using libp2p_ack_stream, this
%% function sends an ack to the worker's stream if connected.
-spec send_ack(pid(), [pos_integer()], boolean()) -> ok.
send_ack(Pid, Seq, Reset) ->
    Pid ! {send_ack, Seq, Reset},
    ok.

%% libp2p_info
%%

%% @private
info(Pid) ->
    catch gen_statem:call(Pid, info, 10000).

%% gen_statem
%%

-spec start_link(reference(), atom(), pid(), string(), [any()], ets:tab()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Ref, Kind, Server, GroupID, DialOptions, TID) ->
    gen_statem:start_link(?MODULE, [Ref, Kind, Server, GroupID,
                                    DialOptions, TID], []).

-spec start_link(reference(), atom(), Stream::pid(), Target::libp2p_crypto:pubkey_bin(), Server::pid(), string(), [any()], ets:tab(), string()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Ref, Kind, StreamPid, Target, Server, GroupID, DialOptions, TID, Path) ->
    gen_statem:start_link(?MODULE, [Ref, Kind, StreamPid, Target, Server,
                                    GroupID, DialOptions, TID, Path], []).

callback_mode() -> state_functions.

-spec init(Args :: term()) -> gen_statem:init_result(atom()).
init([Ref, Kind, StreamPid, Target, Server, GroupID, DialOptions, TID, Path]) ->
    StreamPid ! {identify, Target},
    lager:debug("starting group worker of kind ~p and path: ~p with streamID: ~p",[Kind, Path, StreamPid]),
    process_flag(trap_exit, true),
    {ok, connected,
     update_metadata(#data{ref=Ref, tid=TID, server=Server, kind=Kind, group_id=GroupID,
                          target_backoff=init_targeting_backoff(),
                          connect_retry_backoff=init_connect_retry_backoff(),
                          dial_options=DialOptions,
                          worker_path = Path}),
    {next_event, info, {assign_stream, StreamPid, Path}}};
init([Ref, Kind, Server, GroupID, DialOptions, TID]) ->
    lager:debug("starting group worker of kind: ~p",[Kind]),
    process_flag(trap_exit, true),
    {ok, targeting,
     update_metadata(#data{ref=Ref, tid=TID, server=Server, kind=Kind, group_id=GroupID,
                           target_backoff=init_targeting_backoff(),
                           dial_options=DialOptions,
                           connect_retry_backoff=init_connect_retry_backoff()}),
     ?TRIGGER_TARGETING}.

targeting(cast, clear_target, Data=#data{}) ->
    {keep_state, start_targeting_timer(Data#data{target={undefined, undefined}})};
targeting(cast, {assign_target, Target}, Data=#data{}) ->
    {next_state, connecting, cancel_targeting_timer(Data#data{target=Target}),
     ?TRIGGER_CONNECT_RETRY};
targeting(info, targeting_timeout, Data=#data{}) ->
    libp2p_group_server:request_target(Data#data.server, Data#data.kind, self(), Data#data.ref),
    {keep_state, start_targeting_timer(Data)};
targeting(info, close, Data=#data{}) ->
    {next_state, closing, cancel_targeting_timer(Data)};
targeting(info, {assign_stream, StreamPid}, Data=#data{}) ->
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} -> {next_state, connected, cancel_targeting_timer(NewData)};
        _ -> keep_state_and_data
    end;
targeting(info, {assign_stream, StreamPid, Path}, Data0=#data{}) ->
    Data = Data0#data{worker_path = Path},
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} -> {next_state, connected, cancel_targeting_timer(NewData)};
        _ -> {keep_state, Data}
    end;

targeting(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).

%%
%% Connecting - The worker has a target. Attempt to connect and dial
%% the specified client.
%%

connecting(cast, clear_target, Data=#data{}) ->
    %% When the target is cleared we stop trying to connect and go
    %% back to targeting state. Ensure we klll the existing
    %% connect_pid if any.
    {next_state, targeting, Data#data{connect_pid=kill_pid(Data#data.connect_pid),
                                      target={undefined, undefined}},
     ?TRIGGER_TARGETING};
connecting(cast, {assign_target, Target}, Data=#data{}) ->
    %% When the target is set we kill any existint connect_pid and
    %% cancel a retry timer if set. Then emulate a retry_timeout
    {keep_state, cancel_connect_retry_timer(Data#data{connect_pid=kill_pid(Data#data.connect_pid),
                                                      target=Target}),
     ?TRIGGER_CONNECT_RETRY};
connecting(info, close, Data=#data{}) ->
    {next_state, closing, cancel_connect_retry_timer(Data)};

%% Stream assignment can come in from an externally accepted
%% stream or our own connect_pid. Either way we try to handle the
%% assignment and leave pending connects in place to avoid
%% killing the resulting stream assignment off too quickly.
%% If a path is specified we update the worker to use it
connecting(info, {assign_stream, StreamPid}, Data=#data{target={MAddr, _}}) ->
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} ->
            lager:debug("Assigning stream without path update for ~p", [MAddr]),
            {next_state, connected,
             %% Go the the connected state but delay the reset of the
             %% backoff until we've been in the connected state for
             %% some period of time.
             delayed_cancel_connect_retry_timer(stop_connect_retry_timer(NewData))};
        _ -> {keep_state, Data}
    end;
connecting(info, {assign_stream, StreamPid, Path}, Data0=#data{target={MAddr, _}}) ->
    Data = Data0#data{worker_path = Path},
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} ->
            lager:debug("Assigning stream with pid ~p and path ~p for ~p", [StreamPid, Path, MAddr]),
            {next_state, connected,
             %% Go the the connected state but delay the reset of the
             %% backoff until we've been in the connected state for
             %% some period of time.
             delayed_cancel_connect_retry_timer(stop_connect_retry_timer(NewData))};
        _ -> {keep_state, Data}
    end;
connecting(info, {connect_error, Error}, Data=#data{target={MAddr, _}}) ->
    %% On a connect error we kick of the retry timer, which will fire
    %% a connect_retry_timeout at some point.
    lager:warning("Failed to connect to ~p: ~p", [MAddr, Error]),
    {keep_state, start_connect_retry_timer(Data)};
connecting(info, {'EXIT', ConnectPid, killed}, Data=#data{connect_pid=ConnectPid}) ->
    %% The connect_pid was killed by us. Ignore
    {keep_state, Data#data{connect_pid=undefined}};
connecting(info, {'EXIT', ConnectPid, _Reason}, Data=#data{connect_pid=ConnectPid}) ->
    %% The connect pid crashed for some other reason. Treat like a connect error
    {keep_state, start_connect_retry_timer(Data#data{connect_pid=undefined})};
connecting(info, connect_retry_timeout, Data=#data{target={undefined, _}}) ->
    %% We could end up in a retry timeout with no target when this
    %% worker was assigned a stream without a target, and that stream
    %% died. Fallback to targeting.
    lager:debug("No target and connect retry. Going to targeting"),
    {next_state, targeting,
     cancel_connect_retry_timer(Data#data{connect_pid=kill_pid(Data#data.connect_pid)}),
     ?TRIGGER_TARGETING};
connecting(info, connect_retry_timeout, Data=#data{tid=TID,
                                                   target={MAddr, {SupportedPaths, {M, A}}},
                                                   dial_options=DialOptions,
                                                   connect_pid=ConnectPid}) ->
    %% When the retry timeout fires we kill any exisitng connect_pid
    %% (just to be sure, this should not be needed). Then we spin up
    %% another attempt at connecting and dialing a framedstream based
    %% on the target. We stop, but don't cancel the retry timer since
    %% we can not tell yet whether we need to back of the retries more
    %% times if we fail to connect again.
    %%
    %% We first check whether we've hit or max connect back of delay
    %% and go back to targeting to see if we can acquire a better
    %% target.
    kill_pid(ConnectPid),
    case is_max_connect_retry_timer(Data) of
        false ->
            Parent = self(),
            %% NOTE: why spawn the connect off ?  Why does it matter if the worker is blocked for a bit whilst connecting ?
            Pid = erlang:spawn_link(fun() ->
                case dial(Parent, TID, MAddr, DialOptions, M, A, SupportedPaths) of
                    {error, Error} ->
                        Parent ! {connect_error, Error};
                    {ok, StreamPid, AcceptedPath} ->
                        Parent ! {assign_stream, StreamPid, AcceptedPath}
                end
            end),
            {keep_state, stop_connect_retry_timer(Data#data{connect_pid=Pid})};
        true ->
            lager:debug("max connect retries exceeded, going back to targeting"),
            {next_state, targeting, cancel_connect_retry_timer(Data), ?TRIGGER_TARGETING}
    end;
connecting(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


%%
%% Connectd - The worker has an assigned stream
%%
connected(info, {assign_stream, StreamPid}, Data=#data{}) ->
    %% A new stream assignment came in. We stay in this state
    %% regardless of whether we accept the new stream or not.
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} -> {keep_state, NewData};
        _ -> keep_state_and_data
    end;
connected(info, {assign_stream, StreamPid, Path}, Data0=#data{}) ->
    %% A new stream assignment came in. We stay in this state
    %% regardless of whether we accept the new stream or not.
    %% but in this case we need to update the Path
    Data = Data0#data{worker_path = Path},
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} -> {keep_state, NewData};
        _ -> {keep_state, Data}
    end;
connected(info, {'EXIT', StreamPid, _Reason}, Data=#data{stream_pid=StreamPid, kind=inbound}) ->
    %% don't try to reconnect inbound streams, it never seems to work
    %% this just tells the group server to remove us
    libp2p_group_server:request_target(Data#data.server, Data#data.kind, self(), Data#data.ref),
    {stop, normal, Data};
connected(info, {'EXIT', StreamPid, Reason}, Data=#data{stream_pid=StreamPid, target={MAddr, _}}) ->
    %% The stream we're using died. Let's go back to connecting, but
    %% do not trigger a connect retry right away, (re-)start the
    %% connect retry timer.
    lager:debug("stream ~p with target ~p exited with reason ~p", [StreamPid, MAddr, Reason]),
    {next_state, connecting,
     start_connect_retry_timer(Data#data{stream_pid=update_stream(undefined, Data)})};
connected(cast, clear_target, Data=#data{}) ->
    %% When the target is cleared we go back to targeting after
    %% killing the current stream.
    {next_state, targeting, Data#data{target={undefined, undefined},
                                      stream_pid=update_stream(undefined, Data)},
     ?TRIGGER_TARGETING};
connected(cast, {assign_target, NewTarget}, Data=#data{target=OldTarget}) when NewTarget /= OldTarget ->
    %% When the target is changed from what we have we kill the
    %% current stream and go back to targeting.
    lager:info("Changing target from ~p to ~p", [OldTarget, NewTarget]),
    {next_state, targeting, Data#data{target=NewTarget, stream_pid=update_stream(undefined, Data)},
     ?TRIGGER_TARGETING};
connected(info, close, Data=#data{}) ->
    %% On close we just transition to closing. This keeps the stream
    %% alive for any pending messages until the server decides to
    %% terminate this worker.
    {next_state, closing, Data};
connected(info, connect_retry_cancel_timeout, Data=#data{}) ->
    lager:debug("Cancel connect retry backoff in connected"),
    {keep_state, cancel_connect_retry_timer(Data)};
connected(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


-spec terminate(Reason :: term(), State :: term(), Data :: term()) -> any().
terminate(_Reason, _State, Data=#data{connect_pid=Process}) ->
    kill_pid(Process),
    update_stream(undefined, Data).


%%
%% Closing - The worker is trying to shut down. No more connect
%% attempts are made, but stream assignments are accepted.
%%

closing(info, {assign_stream, StreamPid}, Data=#data{}) ->
    %% A new stream assignment came in. If we accept it we stay in
    %% this state. if not we stay put
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} -> {keep_state, NewData};
        _ -> keep_state_and_data
    end;
closing(info, {assign_stream, StreamPid, Path}, Data0=#data{}) ->
    %% same as above but in this case we should update the path
    Data = Data0#data{worker_path = Path},
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} -> {keep_state, NewData};
        _ -> {keep_state, Data}
    end;

closing(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


handle_assign_stream(StreamPid, Data=#data{stream_pid=undefined}) ->
    {ok, update_metadata(Data#data{stream_pid=update_stream(StreamPid, Data)})};
handle_assign_stream(StreamPid, #data{tid=TID, stream_pid=CurrentStreamPid,
                                      kind=Kind, target = {MAddr, _}}=Data) ->
    lager:debug("handling second stream for target ~p", [MAddr]),
    LocalPeerMAddr = libp2p_swarm:p2p_address(TID),
    TaggedStreams =
        case Kind of
            outbound ->
                %% The existing stream is an outbound stream so the new stream must be an inbound stream from a remote dialer
                lager:debug("local outbound stream: ~p, inbound: ~p", [CurrentStreamPid, StreamPid]),
                #{outbound_stream => CurrentStreamPid, inbound_stream => StreamPid};
            _ ->
                %% The existing stream is an inbound stream so the new stream must be an outgoing stream, a local dialer
                lager:debug("local outbound stream: ~p, inbound: ~p", [StreamPid, CurrentStreamPid]),
                #{outbound_stream => StreamPid, inbound_stream => CurrentStreamPid}
        end,
    %% If local peer's multiaddr is greater lexicographically, then we pick the stream where he is the dialer
    %% otherwise we pick the other stream which will be where he has received an inbound connection
    %% NOTE: MAddr here will be the multi addr of the remote peer
    {WinnerStream, LoserStream} =
        case LocalPeerMAddr > MAddr of
            true ->
                lager:debug("keeping local outgoing stream and dropping inbound", []),
                {maps:get(outbound_stream, TaggedStreams), maps:get(inbound_stream, TaggedStreams)};
            false ->
                lager:debug("dropping local outgoing stream and switching to inbound", []),
                {maps:get(inbound_stream, TaggedStreams), maps:get(outbound_stream, TaggedStreams)}
        end,
    handle_stream_winner_loser(CurrentStreamPid, WinnerStream, LoserStream, Data).

handle_event(cast, {send, Ref, _Msg, _MaybeEncode}, #data{server=Server, stream_pid=undefined}) ->
    %% Trying to send while not connected to a stream
    lager:debug("attempted to send msg ~p but no stream",[_Msg]),
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    keep_state_and_data;
handle_event(cast, {send, Ref, Msg, false}, Data = #data{server=Server, stream_pid=StreamPid}) ->
    lager:debug("gossip sending on stream ~p: ~p",[StreamPid, Msg]),
    handle_send(StreamPid, Server, Ref, Msg, Data);
handle_event(cast, {send, Ref, Msg, true}, Data = #data{server=Server, stream_pid=StreamPid, worker_path = Path}) ->
    lager:debug("gossip sending on stream ~p with path ~p: ~p",[StreamPid, Path, Msg]),
    case (catch libp2p_gossip_stream:encode(Ref, Msg, Path)) of
        {'EXIT', Error} ->
            lager:warning("Error encoding gossip data ~p", [Error]),
            keep_state_and_data;
        Bin ->
            handle_send(StreamPid, Server, Ref, Bin, Data)
    end;
handle_event(cast, clear_target, #data{}) ->
    %% ignore (handled in all states but `closing')
    keep_state_and_data;
handle_event(cast, {assign_target, _Target}, #data{}) ->
    %% ignore (handled in all states but `closing')
    keep_state_and_data;
handle_event(info, {send_ack, _Seq, _Reset}, #data{stream_pid=undefined}) ->
    keep_state_and_data;
handle_event(info, {send_ack, Seq, Reset}, #data{stream_pid=StreamPid}) ->
    StreamPid ! {send_ack, Seq, Reset},
    keep_state_and_data;
handle_event(info, targeting_timeout, #data{}) ->
    %% ignore, handled only by `targeting'
    keep_state_and_data;
handle_event(info, connect_retry_timeout, #data{}) ->
    %% ignore, handled only by `connecting'
    keep_state_and_data;
handle_event(info, connect_retry_cancel_timeout, #data{}) ->
    %% ignore, handled only by `connected'
    keep_state_and_data;
handle_event(info, {connect_error, _}, #data{}) ->
    %% ignore. handled only by `connecting'
    keep_state_and_data;
handle_event(info, close, #data{}) ->
    % ignore (handled in all states but `closing')
    keep_state_and_data;
handle_event(info, {'EXIT', ConnectPid, _Reason}, Data=#data{connect_pid=ConnectPid}) ->
    %% The connect_pid completed, was killed, or crashed. Handled only
    %% by `connecting'.
    {keep_state, Data#data{connect_pid=undefined}};
handle_event(info, {'EXIT', StreamPid, _Reason}, Data=#data{stream_pid=StreamPid}) ->
    %% The stream_pid copmleted, was killed, or crashed. Handled only
    %% by `connected'
    lager:debug("stream pid ~p exited with reason ~p", [StreamPid, _Reason]),
    {keep_state, Data#data{stream_pid=update_stream(undefined, Data)}};
handle_event(info, {'EXIT', _Pid, _Reason}, Data) ->
    {keep_state, Data};
handle_event({call, From}, info, Data=#data{target={Target,_}, stream_pid=StreamPid}) ->
    Info = #{
             module => ?MODULE,
             pid => self(),
             kind => Data#data.kind,
             server => Data#data.server,
             target => Target,
             stream_info =>
                 case StreamPid of
                     undefined -> undefined;
                     _ -> libp2p_framed_stream:info(StreamPid)
                 end
            },
    {keep_state, Data, [{reply, From, Info}]};

handle_event(EventType, Msg, #data{}) ->
    lager:warning("unhandled event ~p: ~p", [EventType, Msg]),
    keep_state_and_data.


%%
%% Utilities
%%

handle_stream_winner_loser(CurrentStream, WinnerStream, LoserStream, Data) when CurrentStream /= WinnerStream->
    unlink(LoserStream),
    spawn(fun() -> libp2p_framed_stream:close(LoserStream) end),
    {ok, update_metadata(Data#data{stream_pid=update_stream(WinnerStream, Data)})};
handle_stream_winner_loser(_CurrentStream, _WinnerStream, LoserStream, _Data) ->
    unlink(LoserStream),
    spawn(fun() -> libp2p_framed_stream:close(LoserStream) end),
    false.

handle_send(StreamPid, Server, Ref, Bin, Data = #data{kind=Kind})->
    Result = libp2p_framed_stream:send(StreamPid, Bin),
    libp2p_group_server:send_result(Server, Ref, Result),
    case Result of
        {error, _} when Kind == inbound ->
            %% this just tells the group server to remove us
            libp2p_group_server:request_target(Data#data.server, Data#data.kind, self(), Data#data.ref),
            {stop, normal, Data};
        {error, _Reason} ->
            lager:debug("send via stream ~p failed with reason ~p", [StreamPid, Result]),
            {next_state, connecting, Data#data{stream_pid=update_stream(undefined, Data)},
             ?TRIGGER_CONNECT_RETRY};
        _ ->
            lager:debug("send via stream ~p successful", [StreamPid]),
            keep_state_and_data
    end.

init_targeting_backoff() ->
    backoff:type(backoff:init(?MIN_TARGETING_RETRY_TIMEOUT,
                              ?MAX_TARGETING_RETRY_TIMEOUT), normal).

-spec start_targeting_timer(#data{}) -> #data{}.
start_targeting_timer(Data=#data{target_timer=undefined}) ->
    Delay = backoff:get(Data#data.target_backoff),
    Timer = erlang:send_after(Delay, self(), targeting_timeout),
    Data#data{target_timer=Timer};
start_targeting_timer(Data=#data{target_timer=CurrentTimer}) ->
    erlang:cancel_timer(CurrentTimer),
    {Delay, NewBackOff} = backoff:fail(Data#data.target_backoff),
    Timer = erlang:send_after(Delay, self(), targeting_timeout),
    Data#data{target_timer=Timer, target_backoff=NewBackOff}.

-spec cancel_targeting_timer(#data{}) -> #data{}.
cancel_targeting_timer(Data=#data{target_timer=undefined}) ->
    {_, NewBackOff} = backoff:succeed(Data#data.target_backoff),
    Data#data{target_backoff=NewBackOff};
cancel_targeting_timer(Data=#data{target_timer=Timer}) ->
    erlang:cancel_timer(Timer),
    {_, NewBackOff} = backoff:succeed(Data#data.target_backoff),
    Data#data{target_backoff=NewBackOff, target_timer=undefined}.


init_connect_retry_backoff() ->
    backoff:type(backoff:init(?MIN_CONNECT_RETRY_TIMEOUT,
                              ?MAX_CONNECT_RETRY_TIMEOUT), normal).

start_connect_retry_timer(Data=#data{connect_retry_timer=undefined}) ->
    Delay = backoff:get(Data#data.connect_retry_backoff),
    Timer = erlang:send_after(Delay, self(), connect_retry_timeout),
    Data#data{connect_retry_timer=Timer};
start_connect_retry_timer(Data=#data{connect_retry_timer=CurrentTimer}) ->
    erlang:cancel_timer(CurrentTimer),
    {Delay, NewBackOff} = backoff:fail(Data#data.connect_retry_backoff),
    Timer = erlang:send_after(Delay, self(), connect_retry_timeout),
    Data#data{connect_retry_timer=Timer, connect_retry_backoff=NewBackOff}.

stop_connect_retry_timer(Data=#data{connect_retry_timer=undefined}) ->
    %% If we don't have a time we can cancel we make up a ref so that
    %% the next start_timer behaves as if the backoff needs to
    %% happen. This is required at the targeting->connecting
    %% transition where the timer is not initialized yet.
    Data#data{connect_retry_timer=make_ref()};
stop_connect_retry_timer(Data=#data{connect_retry_timer=Timer}) ->
    %% We do not clear the connect_retry_timer to get a future
    %% start_connect_retry_timer to continue with the backoff
    erlang:cancel_timer(Timer),
    Data.

cancel_connect_retry_timer(Data=#data{connect_retry_timer=undefined}) ->
    {_, NewBackOff} = backoff:succeed(Data#data.connect_retry_backoff),
    Data#data{connect_retry_backoff=NewBackOff};
cancel_connect_retry_timer(Data=#data{connect_retry_timer=Timer}) ->
    erlang:cancel_timer(Timer),
    {_, NewBackOff} = backoff:succeed(Data#data.connect_retry_backoff),
    Data#data{connect_retry_backoff=NewBackOff, connect_retry_timer=undefined}.


delayed_cancel_connect_retry_timer(Data=#data{connect_retry_cancel_timer=undefined}) ->
    Timer = erlang:send_after(?CONNECT_RETRY_CANCEL_TIMEOUT,
                              self(), connect_retry_cancel_timeout),
    Data#data{connect_retry_cancel_timer=Timer};
delayed_cancel_connect_retry_timer(Data=#data{connect_retry_cancel_timer=CurrentTimer}) ->
    erlang:cancel_timer(CurrentTimer),
    Timer = erlang:send_after(?CONNECT_RETRY_CANCEL_TIMEOUT,
                              self(), connect_retry_cancel_timeout),
    Data#data{connect_retry_cancel_timer=Timer}.


is_max_connect_retry_timer(Data=#data{}) ->
    Delay = backoff:get(Data#data.connect_retry_backoff),
    Delay >= ?MAX_CONNECT_RETRY_TIMEOUT.


update_stream(undefined, #data{stream_pid=undefined}) ->
    undefined;
update_stream(undefined,  #data{stream_pid=Pid, target={MAddr, _}, kind=Kind, server=Server}) ->
    catch unlink(Pid),
    spawn(fun() -> libp2p_framed_stream:close(Pid) end),
    libp2p_group_server:send_ready(Server, MAddr, Kind, false),
    undefined;
update_stream(StreamPid, #data{stream_pid=undefined, target={MAddr, _}, kind=Kind, server=Server}) ->
    link(StreamPid),
    libp2p_group_server:send_ready(Server, MAddr, Kind, true),
    StreamPid;
update_stream(StreamPid, #data{stream_pid=StreamPid}) ->
    StreamPid;
update_stream(StreamPid, #data{stream_pid=Pid, target={MAddr, _}, server=Server, kind=Kind}) ->
    link(StreamPid),
    catch unlink(Pid),
    spawn(fun() -> libp2p_framed_stream:close(Pid) end),
    %% we have a new stream, re-advertise our ready status
    libp2p_group_server:send_ready(Server, MAddr, Kind, true),
    StreamPid.

-spec kill_pid(pid() | undefined) -> undefined.
kill_pid(undefined) ->
    undefined;
kill_pid(Pid) ->
    erlang:unlink(Pid),
    erlang:exit(Pid, kill),
    Pid.

-spec update_metadata(#data{}) -> #data{}.
update_metadata(Data=#data{}) ->
    IndexOrKind = fun(V) when is_atom(V) ->
                          {kind, V};
                     (I) when is_integer(I) ->
                          {index, I}
                  end,
    libp2p_lager_metadata:update(
      [
       {target, Data#data.target},
       IndexOrKind(Data#data.kind),
       {group_id, Data#data.group_id}
      ]),
    Data.

-spec dial(Parent::pid(), TID::ets:tab(), Peer::string(), DialOptions::[any()], Module::atom(),
            Args::[any()], SupportedPaths::[string()])->
                    {'ok', StreamPid::pid(), Path::string()} |
                    {'error', any()}.
dial(Parent, TID, Peer, DialOptions,  Module, Args, SupportedPaths) ->
    lager:debug("(~p) Swarm ~p is dialing peer ~p with paths ~p",[Parent, TID, Peer, SupportedPaths]),
    DialFun =
        fun
            Dial([])->
                lager:debug("(~p) dialing group worker stream failed, no compatible paths versions",[Parent]),
                {error, no_supported_paths};
            Dial([Path | Rest]) ->
                case do_dial(TID, Peer, DialOptions, Module, Args, Path) of
                        {ok, Stream} ->
                            lager:debug("(~p) dialing group worker stream successful, stream pid: ~p, path version: ~p", [Parent, Stream, Path]),
                            {ok, Stream, Path};
                        {error, protocol_unsupported} ->
                            lager:debug("(~p) dialing group worker stream failed with path version: ~p, trying next supported path version",[Parent, Path]),
                            Dial(Rest);
                        {error, Reason} ->
                            lager:debug("(~p) dialing group worker stream failed: ~p",[Parent, Reason]),
                            {error, Reason}
                end
        end,
    DialFun(SupportedPaths).

-spec do_dial(TID::ets:tab(), Peer::string(), DialOptions::[any()], Module::atom(),
            Args::[any()], Path::string())->
                    {'ok', StreamPid::pid()} |
                    {'error', any()}.
do_dial(TID, Peer, DialOptions, Module, Args, Path)->
    libp2p_swarm:dial_framed_stream(TID,
                                    Peer,
                                    Path,
                                    DialOptions,
                                    5000,
                                    Module,
                                    [Path | Args]).
