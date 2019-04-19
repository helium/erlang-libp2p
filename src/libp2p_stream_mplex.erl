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

-record(state, {
                socket :: gen_tcp:socket(),
                next_stream_id=0 :: non_neg_integer(),
                worker_opts :: map(),
                received_workers=#{} :: #{non_neg_integer() => pid()},
                max_received_workers :: pos_integer(),
                initiated_workers=#{} :: #{non_neg_integer() => pid()}
               }).

%% API

-spec open(pid()) -> {ok, pid()} | {error, term()}.
open(Pid) ->
    gen_server:call(open, Pid).

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


handle_packet(_Kind, [Header | _], Packet, State=#state{worker_opts=WorkerOpts0,
                                                        max_received_workers=MaxReceivedWorkers,
                                                        received_workers=ReceivedWorkers,
                                                        initiated_workers=InitiatedWorkers}) ->
    WorkerDo = fun(StreamID, Map, Fun) ->
                       case maps:get(StreamID, Map, false) of
                           false ->
                               {ok, State};
                           WorkerPid when is_pid(WorkerPid) ->
                               Fun(WorkerPid),
                               {ok, State}
                       end
               end,

    case decode_header(Header) of
        {StreamID, ?FLAG_NEW_STREAM} when map_size(ReceivedWorkers) > MaxReceivedWorkers ->
            lager:info("Declining inbound stream: ~p: max inbound streams (~p) reached",
                       [StreamID, MaxReceivedWorkers]),
            Packet = encode_packet(StreamID, server, reset),
            {ok, State, [{send, Packet}]};
        {StreamID, ?FLAG_NEW_STREAM} ->
            WorkerOpts = WorkerOpts0#{stream_id => StreamID,
                                      socket => State#state.socket},
            {ok, WorkerPid} = libp2p_stream_mplex_worker:start_link(server, WorkerOpts),
            {ok, State#state{received_workers=ReceivedWorkers#{StreamID => WorkerPid}}};

        {StreamID, ?FLAG_MSG_INITIATOR} ->
            case maps:get(StreamID, ReceivedWorkers, false) of
                false ->
                    lager:debug("Ignoring data for a non existng inbound stream ~p", [StreamID]),
                    {ok, State};
                WorkerPid when is_pid(WorkerPid) ->
                    libp2p_stream_mplex_worker:handle_packet(WorkerPid, Packet),
                    {ok, State}
            end;
        {StreamID, ?FLAG_MSG_RECEIVER} ->
            case maps:get(StreamID, InitiatedWorkers, false) of
                false ->
                    lager:debug("Ignoring data for a non existng outbound stream ~p", [StreamID]),
                    {ok, State};
                WorkerPid when is_pid(WorkerPid) ->
                    libp2p_stream_mplex_worker:handle_packet(WorkerPid, Packet),
                    {ok, State}
            end;

        {StreamID, ?FLAG_RESET_INITIATOR} ->
            WorkerDo(StreamID, ReceivedWorkers,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_reset(WorkerPid)
                     end);

        {StreamID, ?FLAG_RESET_RECEIVER} ->
            WorkerDo(StreamID, InitiatedWorkers,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_reset(WorkerPid)
                     end);

        {StreamID, ?FLAG_CLOSE_INITIATOR} ->
            WorkerDo(StreamID, ReceivedWorkers,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_close(WorkerPid)
                     end);

        {StreamID, ?FLAG_CLOSE_RECEIVER} ->
            WorkerDo(StreamID, InitiatedWorkers,
                     fun(WorkerPid) ->
                             libp2p_stream_mplex_worker:handle_close(WorkerPid)
                     end);

        _ ->
            {ok, State}
    end.


handle_command(_Kind, open, _From, State=#state{next_stream_id=StreamID,
                                                worker_opts=WorkerOpts0,
                                                initiated_workers=InitiatedWorkers}) ->
    WorkerOpts = WorkerOpts0#{stream_id => StreamID,
                              socket => State#state.socket},
    {ok, WorkerPid} = libp2p_stream_mplex_worker:start_link(client, WorkerOpts),
    Packet = encode_packet(StreamID, client, new),
    {reply, {ok, WorkerPid},
     State#state{initiated_workers=InitiatedWorkers#{StreamID => WorkerPid},
                 next_stream_id=StreamID + 1},
     [{send, Packet}]};

handle_command(_Kind, Cmd, _From, State=#state{}) ->
    lager:warning("Unhandled command ~p", [Cmd]),
    {reply, ok, State}.


handle_info(_Kind, _Msg, State=#state{}) ->
    {ok, State}.


%%
%% Internal
%%

encode_header(StreamID, Flag) ->
    (StreamID bsl 3) bor Flag.

decode_header(Val) when is_integer(Val) ->
    Flag = Val band 16#07,
    StreamID = Val bsr 3,
    {StreamID, Flag}.

-spec encode_packet(stream_id(), libp2p_stream:kind(), flag()) -> binary().
encode_packet(StreamID, Kind, Flag) ->
    encode_packet(StreamID, Kind, Flag, <<>>).

-spec encode_packet(stream_id(), libp2p_stream:kind(), flag(), binary()) -> binary().
encode_packet(StreamID, Kind, Flag, Data) ->
    Header = [encode_header(StreamID, encode_flag(Kind, Flag)), byte_size(Data)],
    libp2p_packet:encode_packet(?PACKET_SPEC, Header, Data).

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
