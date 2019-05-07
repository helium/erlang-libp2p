-module(libp2p_stream_mplex).

-behavior(libp2p_stream).

-export([init/2,
         handle_packet/4,
         handle_info/3,
         handle_command/4,
         protocol_id/0
        ]).
-export([encode_packet/3,
         encode_packet/4
        ]).

-type flag() :: new | close | reset | msg.
-type stream_id() :: non_neg_integer().

-export_type([flag/0, stream_id/0]).

-define(DEFAULT_MAX_RECEIVED_STREAMS, 500).

-define(FLAG_NEW_STREAM, 0).
-define(FLAG_MSG_RECEIVER, 1).
-define(FLAG_MSG_INITIATOR, 2).
-define(FLAG_CLOSE_RECEIVER, 3).
-define(FLAG_CLOSE_INITIATOR, 4).
-define(FLAG_RESET_RECEIVER, 5).
-define(FLAG_RESET_INITIATOR, 6).

-define(PACKET_SPEC, [varint, varint]).


-type worker_key() :: {libp2p_stream:kind(), stream_id()}.

-record(state, {
                next_stream_id=0 :: non_neg_integer(),
                worker_opts :: map(),
                workers=#{} :: #{worker_key() => pid()},
                worker_pids=#{} :: #{pid() => worker_key()},
                max_received_workers :: pos_integer(),
                count_received_workers=0 :: non_neg_integer()
               }).

%% API

protocol_id() ->
    <<"/mplex/6.7.0">>.

-spec encode_packet(stream_id(), libp2p_stream:kind(), flag()) -> binary().
encode_packet(StreamID, Kind, Flag) ->
    encode_packet(StreamID, Kind, Flag, <<>>).

-spec encode_packet(stream_id(), libp2p_stream:kind(), flag(), binary()) -> binary().
encode_packet(StreamID, Kind, Flag, Data) ->
    Header = [encode_header(StreamID, encode_flag(Kind, Flag)), byte_size(Data)],
    libp2p_packet:encode_packet(?PACKET_SPEC, Header, Data).

%% libp2p_stream

init(_Kind, Opts=#{send_fn := SendFun}) ->
    WorkerOpts = maps:get(mod_opts, Opts, #{}),
    {ok, #state{
            max_received_workers=maps:get(max_received_streams, Opts, ?DEFAULT_MAX_RECEIVED_STREAMS),
            worker_opts=WorkerOpts#{send_fn => SendFun}
           },
     [{packet_spec, ?PACKET_SPEC},
      {active, once}]}.


handle_packet(_Kind, [Header | _], Packet, State=#state{workers=Workers,
                                                        max_received_workers=MaxReceivedWorkers,
                                                        count_received_workers=CountReceivedWorkers}) ->
    WorkerDo = fun(Kind, StreamID, Fun) ->
                       case maps:get({Kind, StreamID}, Workers, false) of
                           false ->
                               {noreply, State, [{active, once}]};
                           WorkerPid ->
                               Fun(WorkerPid),
                               {noreply, State, [{active, once}]}
                       end
               end,

    case decode_header(Header) of
        {StreamID, ?FLAG_NEW_STREAM} when CountReceivedWorkers > MaxReceivedWorkers ->
            lager:info("Declining inbound stream: ~p: max inbound streams (~p) reached",
                       [StreamID, MaxReceivedWorkers]),
            Packet = encode_packet(StreamID, server, reset),
            {noreply, State, [{send, Packet}, {active, once}]};
        {StreamID, ?FLAG_NEW_STREAM} ->
            {ok, _, NewState} = start_worker({server, StreamID}, State),
            {noreply, NewState, [{active, once}]};

        {StreamID, ?FLAG_MSG_INITIATOR} ->
            WorkerDo(server, StreamID,
                     fun(WorkerPid) ->
                             WorkerPid ! {packet, Packet}
                     end);
        {StreamID, ?FLAG_MSG_RECEIVER} ->
            WorkerDo(client, StreamID,
                     fun(WorkerPid) ->
                             WorkerPid ! {packet, Packet}
                     end);

        {StreamID, ?FLAG_RESET_INITIATOR} ->
            WorkerDo(server, StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_reset(WorkerPid)
                     end);

        {StreamID, ?FLAG_RESET_RECEIVER} ->
            WorkerDo(client, StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_reset(WorkerPid)
                     end);

        {StreamID, ?FLAG_CLOSE_INITIATOR} ->
            WorkerDo(server, StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_close(WorkerPid)
                     end);

        {StreamID, ?FLAG_CLOSE_RECEIVER} ->
            WorkerDo(client ,StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_close(WorkerPid)
                     end);

        _ ->
            {noreply, State}
    end.

handle_command(_Kind, open, _From, State=#state{next_stream_id=StreamID}) ->
    case start_worker({client, StreamID}, State) of
        {ok, Pid, NewState} ->
            Packet = encode_packet(StreamID, client, new),
            {reply, {ok, Pid}, NewState#state{next_stream_id=StreamID + 1},
             [{send, Packet}]};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_command(_Kind, Cmd, _From, State=#state{}) ->
    lager:warning("Unhandled command ~p", [Cmd]),
    {reply, ok, State}.


handle_info(_, {'EXIT', WorkerPid, Reason}, State=#state{}) ->
    case remove_worker(WorkerPid, State) of
        {{Kind, StreamID}, NewState} ->
            %% Don't bother sending resets when the worker already has
            %% or if we are getting shut down
            case Reason of
                normal ->
                    {noreply, NewState};
                shutdown ->
                    {noreply, NewState};
                _Other ->
                    Packet = encode_packet(StreamID, Kind, reset),
                    {noreply, NewState, [{send, Packet}]}
            end;
        false ->
            {noreply, State}
    end;

handle_info(_Kind, Msg, State=#state{}) ->
    lager:warning("Unhandled info ~p", [Msg]),
    {noreply, State}.


%%
%% Internal
%%

-spec start_worker(worker_key(), #state{}) -> {ok, pid(), #state{}} | {error, term()}.
start_worker(WorkerKey={Kind, StreamID}, State=#state{worker_opts=WorkerOpts0,
                                                      workers=Workers,
                                                      worker_pids=WorkerPids,
                                                      count_received_workers=CountReceived}) ->
    WorkerOpts = WorkerOpts0#{stream_id => StreamID},
    case libp2p_stream_mplex_worker:start_link(Kind, WorkerOpts) of
        {ok, WorkerPid} ->
            NewCountReceived = case Kind of
                                   server -> CountReceived + 1;
                                   client -> CountReceived
                               end,
            {ok, WorkerPid, State#state{workers=Workers#{WorkerKey => WorkerPid},
                                        worker_pids=WorkerPids#{WorkerPid => WorkerKey},
                                        count_received_workers=NewCountReceived}};
        {error, Error} ->
            {error, Error}
    end.

-spec remove_worker(worker_key() | pid(), #state{}) -> {worker_key(), #state{}} | false.
remove_worker(WorkerKey={Kind, _StreamID}, State=#state{workers=Workers,
                                                        worker_pids=WorkerPids,
                                                        count_received_workers=CountReceived}) ->
    case maps:take(WorkerKey, Workers) of
        error -> false;
        {WorkerPid, NewWorkers} ->
            NewCountReceived = case Kind of
                                   server -> CountReceived - 1;
                                   client -> CountReceived
                               end,
            {WorkerKey, State#state{workers=NewWorkers,
                                    worker_pids=maps:remove(WorkerPid, WorkerPids),
                                    count_received_workers=NewCountReceived}}
    end;
remove_worker(WorkerPid, State=#state{}) when is_pid(WorkerPid) ->
    case maps:get(WorkerPid, State#state.worker_pids, false) of
        false -> false;
        WorkerKey when is_tuple(WorkerKey) -> remove_worker(WorkerKey, State)
    end.


encode_header(StreamID, Flag) ->
    (StreamID bsl 3) bor Flag.

decode_header(Val) when is_integer(Val) ->
    Flag = Val band 16#07,
    StreamID = Val bsr 3,
    {StreamID, Flag}.

-spec encode_flag(libp2p_stream:kind(), flag()) -> non_neg_integer().
encode_flag(_, new) ->
    ?FLAG_NEW_STREAM;
encode_flag(client, reset) ->
    ?FLAG_RESET_INITIATOR;
encode_flag(server, reset) ->
    ?FLAG_RESET_RECEIVER;
encode_flag(client, close) ->
    ?FLAG_CLOSE_INITIATOR;
encode_flag(server, close) ->
    ?FLAG_CLOSE_RECEIVER;
encode_flag(client, msg) ->
    ?FLAG_MSG_INITIATOR;
encode_flag(server, msg) ->
    ?FLAG_MSG_RECEIVER.
