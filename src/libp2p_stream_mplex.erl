-module(libp2p_stream_mplex).

-behavior(libp2p_stream).

-export([init/2, handle_packet/4, handle_info/3, handle_command/4]).
-export([encode_packet/3,
         encode_packet/4,
         open/1,
         %% substream API
         reset/1,
         close/1]).

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
                socket :: gen_tcp:socket(),
                next_stream_id=0 :: non_neg_integer(),
                worker_opts :: map(),
                worker_monitors=#{} :: #{reference() => worker_key()},
                workers=#{} :: #{worker_key() => pid()},
                max_received_workers :: pos_integer(),
                count_received_workers=0 :: non_neg_integer()
               }).

%% API

-spec open(pid()) -> {ok, pid()} | {error, term()}.
open(Pid) ->
    gen_server:call(open, Pid).

-spec encode_packet(stream_id(), libp2p_stream:kind(), flag()) -> binary().
encode_packet(StreamID, Kind, Flag) ->
    encode_packet(StreamID, Kind, Flag, <<>>).

-spec encode_packet(stream_id(), libp2p_stream:kind(), flag(), binary()) -> binary().
encode_packet(StreamID, Kind, Flag, Data) ->
    Header = [encode_header(StreamID, encode_flag(Kind, Flag)), byte_size(Data)],
    libp2p_packet:encode_packet(?PACKET_SPEC, Header, Data).

%% Substream API

reset(WorkerPid) ->
    libp2p_stream_mplex_worker:reset(WorkerPid).

close(WorkerPid) ->
    libp2p_stream_mplex_worker:close(WorkerPid).

%% libp2p_stream

init(_Kind, Opts=#{socket := Sock}) ->
    {ok, #state{
            socket=Sock,
            max_received_workers = maps:get(max_received_streams, Opts, ?DEFAULT_MAX_RECEIVED_STREAMS),
            worker_opts =  maps:get(worker_opts, Opts, #{})
           },
     [{packet_spec, ?PACKET_SPEC}]}.


handle_packet(_Kind, [Header | _], Packet, State=#state{workers=Workers,
                                                        max_received_workers=MaxReceivedWorkers,
                                                        count_received_workers=CountReceivedWorkers}) ->
    WorkerDo = fun(Kind, StreamID, Fun) ->
                       case maps:get({Kind, StreamID}, Workers, false) of
                           false ->
                               {ok, State};
                           WorkerPid ->
                               Fun(WorkerPid),
                               {ok, State}
                       end
               end,

    case decode_header(Header) of
        {StreamID, ?FLAG_NEW_STREAM} when CountReceivedWorkers > MaxReceivedWorkers ->
            lager:info("Declining inbound stream: ~p: max inbound streams (~p) reached",
                       [StreamID, MaxReceivedWorkers]),
            Packet = encode_packet(StreamID, server, reset),
            {ok, State, [{send, Packet}]};
        {StreamID, ?FLAG_NEW_STREAM} ->
            {_, NewState} = start_worker(server,StreamID, State),
            {ok, NewState};

        {StreamID, ?FLAG_MSG_INITIATOR} ->
            WorkerDo(server, StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_packet(WorkerPid, Packet)
                     end);
        {StreamID, ?FLAG_MSG_RECEIVER} ->
            WorkerDo(client, StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_packet(WorkerPid, Packet)
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
            WorkerDo(cliemt ,StreamID,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_close(WorkerPid)
                     end);

        _ ->
            {ok, State}
    end.


handle_command(_Kind, open, _From, State=#state{next_stream_id=StreamID}) ->
    {WorkerPid, NewState} = start_worker(client, StreamID, State),
    Packet = encode_packet(StreamID, client, new),
    {reply, {ok, WorkerPid}, NewState#state{next_stream_id=StreamID + 1},
     [{send, Packet}]};

handle_command(_Kind, Cmd, _From, State=#state{}) ->
    lager:warning("Unhandled command ~p", [Cmd]),
    {reply, ok, State}.


handle_info(_Kind, {'DOWN', Monitor, process, _Pid, Reason}, State=#state{worker_monitors=WorkerMonitors}) ->
    case maps:take(Monitor, WorkerMonitors) of
        {WorkerKey={Kind, StreamID}, NewWorkerMonitors} ->
            NewState = State#state{workers=maps:remove(WorkerKey, State#state.workers),
                                   worker_monitors=NewWorkerMonitors},
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
        error ->
            {noreply, State}
    end;
handle_info(_Kind, {'EXIT', _WorkerPid, _Reason}, State=#state{}) ->
    %% Ignore EXITs since they come from worker pids which are
    %% monitored and handled in 'DOWN'
    {noreply, State};

handle_info(_Kind, _Msg, State=#state{}) ->
    {ok, State}.


%%
%% Internal
%%

-spec start_worker(libp2p_stream:kind(), stream_id(), #state{}) -> {pid(), #state{}}.
start_worker(Kind, StreamID, State=#state{worker_opts=WorkerOpts0,
                                          workers=Workers,
                                          count_received_workers=CountReceived,
                                          worker_monitors=Monitors}) ->
    WorkerOpts = WorkerOpts0#{stream_id => StreamID,
                              socket => State#state.socket},
    {ok, WorkerPid} = libp2p_stream_mplex_worker:start_link(Kind, WorkerOpts),
    Monitor = erlang:monitor(process, WorkerPid),
    WorkerKey = {Kind, StreamID},
    NewCountReceived = case Kind of
                           server -> CountReceived + 1;
                           client -> CountReceived
                       end,
    {WorkerPid, State#state{workers=Workers#{WorkerKey => WorkerPid},
                            worker_monitors=Monitors#{Monitor => WorkerKey},
                            count_received_workers=NewCountReceived}}.

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
