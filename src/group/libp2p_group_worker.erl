-module(libp2p_group_worker).

-behaviour(gen_statem).
-behavior(libp2p_info).

-type stream_client_spec() :: {Path::string(), {Module::atom(), Args::[any()]}}.
-export_type([stream_client_spec/0]).

%% API
-export([start_link/5, start_link/6,
         assign_target/2, clear_target/1,
         assign_stream/2, send/3, send_ack/3, close/1]).

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
-define(CONNECT_TIMEOUT, 5000).

-type target() :: {MAddr::string(), Spec::stream_client_spec()}.

-record(data,
        { ref :: reference(),
          tid :: ets:tab(),
          kind :: atom() | pos_integer(),
          group_id :: string(),
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
          stream_pid=undefined :: undefined | pid()
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

%% @doc Sends a given `Data' binary on it's stream asynchronously. The given `Ref' is
%% used to indicate the send result to the server for the worker.
%%
%% @see libp2p_group_server:send_result/3
-spec send(pid(), term(), any()) -> ok.
send(Pid, Ref, Data) ->
    gen_statem:cast(Pid, {send, Ref, Data}).

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

-spec start_link(reference(), atom(), pid(), string(), ets:tab()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Ref, Kind, Server, GroupID, TID) ->
    gen_statem:start_link(?MODULE, [Ref, Kind, Server, GroupID, TID], []).

-spec start_link(reference(), atom(), Stream::pid(), Server::pid(), string(), ets:tab()) ->
                        {ok, Pid :: pid()} |
                        ignore |
                        {error, Error :: term()}.
start_link(Ref, Kind, StreamPid, Server, GroupID, TID) ->
    gen_statem:start_link(?MODULE, [Ref, Kind, StreamPid, Server, GroupID, TID], []).

callback_mode() -> state_functions.

-spec init(Args :: term()) -> gen_statem:init_result(atom()).
init([Ref, Kind, StreamPid, Server, GroupID, TID]) ->
    process_flag(trap_exit, true),
    {ok, connected,
     update_metadata(#data{ref=Ref, tid=TID, server=Server, kind=Kind, group_id=GroupID,
                          target_backoff=init_targeting_backoff(),
                          connect_retry_backoff=init_connect_retry_backoff()}),
    {next_event, info, {assign_stream, StreamPid}}};
init([Ref, Kind, Server, GroupID, TID]) ->
    process_flag(trap_exit, true),
    {ok, targeting,
     update_metadata(#data{ref=Ref, tid=TID, server=Server, kind=Kind, group_id=GroupID,
                          target_backoff=init_targeting_backoff(),
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
connecting(info, {assign_stream, StreamPid}, Data=#data{target={MAddr, _}}) ->
    %% Stream assignment can come in from an externally accepted
    %% stream or our own connct_pid. Either way we try to handle the
    %% assignment and leave pending connects in place to avoid
    %% killing the resulting stream assignemt of too quick.
    case handle_assign_stream(StreamPid, Data) of
        {ok, NewData} ->
            lager:debug("Assigning stream for ~p", [MAddr]),
            {next_state, connected,
             %% Go the the connected state but delay the reset of the
             %% backoff until we've been in the connected state for
             %% some period of time.
             delayed_cancel_connect_retry_timer(stop_connect_retry_timer(NewData))};
        _ -> keep_state_and_data
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
                                                   target={MAddr, {Path, {M, A}}},
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
            Pid = erlang:spawn_link(fun() ->
                LocalAddr = libp2p_swarm:p2p_address(TID),
                %% its possible that after exchanging identities two peers will be assigned each other as a target
                %% and end up dialing each other at pretty much the same time
                %% resulting in streams being assigned for the first dial, followed by a second set of streams for the second dial
                %% there is/was then a coin toss ( see handle_assign_stream ) as to which streams win ( we dont want two streams between the same set of peers )
                %% both peers could get opposite sides of the coin and end up with both streams streams being closed by opposite peers
                %% to avoid this we will only have one side perform the dialing based on a decision around data available on both ends
                %% as such, we lexicographically compare the local peer addr with that of the remote peers addr
                %% peer with highest order gets to do the stream dial
                case LocalAddr > MAddr of
                    true ->
                        lager:debug("(~p) peer ~p will dial a stream to remote peer ~p", [Parent, LocalAddr, MAddr]),
                        case libp2p_swarm:dial_framed_stream(TID, MAddr, Path, M, A) of
                            {error, Error} ->
                                Parent ! {connect_error, Error};
                            {ok, StreamPid} ->
                                Parent ! {assign_stream, StreamPid}
                        end;
                false ->
                        %% if our local peer is not performing the dial, we will attempt to connect to the remote peer
                        %% this is to handle scenarios where we were hoping to dial a peer to which we had not yet connected
                        %% such as when we are gossiped a new peer from an already connected peer
                        %% the dial above would have first performed this connection and then proceeded to dial a stream
                        %% If we dont perform the connect here then we will end up never connecting to gossiped peers with an address with a lower lex order
                        lager:debug("(~p) peer ~p will not dial a stream to remote peer ~p, but will establish a connection to it if not already active...",[Parent, LocalAddr, MAddr]),
                        libp2p_transport:connect_to(MAddr, [], ?CONNECT_TIMEOUT, TID)
                end
            end),
            {keep_state, stop_connect_retry_timer(Data#data{connect_pid=Pid})};
        true ->
            lager:debug("max connect retries exceeded, going back to targeting"),
            libp2p_group_server:clear_target(Data#data.server, Data#data.kind, self(), Data#data.ref),
            {next_state, targeting, cancel_connect_retry_timer(Data#data{target = undefined}), ?TRIGGER_TARGETING}
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

closing(EventType, Msg, Data) ->
    handle_event(EventType, Msg, Data).


handle_assign_stream(StreamPid, Data=#data{stream_pid=undefined}) ->
    {ok, update_metadata(Data#data{stream_pid=update_stream(StreamPid, Data)})};
handle_assign_stream(StreamPid, Data=#data{stream_pid=_CurrentStreamPid}) ->
    %% If send_pid known we have an existing stream. Do not replace.
    case rand:uniform(2) of
        1 ->
            lager:debug("Loser stream ~p (addr_info ~p) to assigned stream ~p (addr_info ~p)",
                        [StreamPid, libp2p_framed_stream:addr_info(StreamPid),
                         _CurrentStreamPid, libp2p_framed_stream:addr_info(_CurrentStreamPid)]),
            libp2p_framed_stream:close(StreamPid),
            false;
        _ ->
            %% lager:debug("Lucky winner stream ~p (addr_info ~p) overriding existing stream ~p (addr_info ~p)",
            %%              [StreamPid, libp2p_framed_stream:addr_info(StreamPid),
            %%               _CurrentStreamPid, libp2p_framed_stream:addr_info(_CurrentStreamPid)]),
            {ok, update_metadata(Data#data{stream_pid=update_stream(StreamPid, Data)})}
    end.


handle_event(cast, {send, Ref, _Bin}, #data{server=Server, stream_pid=undefined}) ->
    %% Trying to send while not connected to a stream
    libp2p_group_server:send_result(Server, Ref, {error, not_connected}),
    keep_state_and_data;
handle_event(cast, {send, Ref, Bin}, Data = #data{server=Server, stream_pid=StreamPid}) ->
    Result = libp2p_framed_stream:send(StreamPid, Bin),
    libp2p_group_server:send_result(Server, Ref, Result),
    case Result of
        {error, _Reason} ->
            %lager:info("send failed with reason ~p", [Result]),
            {next_state, connecting, Data#data{stream_pid=update_stream(undefined, Data)},
             ?TRIGGER_CONNECT_RETRY};
        _ ->
            keep_state_and_data
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
update_stream(undefined, #data{stream_pid=Pid, target={MAddr, _}, kind=Kind, server=Server}) ->
    catch unlink(Pid),
    libp2p_framed_stream:close(Pid),
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
    libp2p_framed_stream:close(Pid),
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
