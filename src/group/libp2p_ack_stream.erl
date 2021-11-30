-module(libp2p_ack_stream).

-include("pb/libp2p_ack_stream_pb.hrl").

-behavior(libp2p_framed_stream).

-callback handle_data(State::any(), Ref::any(), {Msg::binary(), Seq::pos_integer()}) -> ok.
-callback accept_stream(State::any(),
                        Stream::pid(), Path::string()) -> Ref :: reference().
-callback handle_ack(State::any(), Ref::any(), Seq::[pos_integer()], Reset::boolean()) -> ok.

%% API
-export([send_ack/3]).
%% libp2p_framed_stream
-export([server/4, client/2, init/3, handle_data/3, handle_send/5, handle_info/3]).


-record(state,
        { connection :: libp2p_connection:connection(),
          ack_module :: atom(),
          ack_state :: any(),
          ack_ref :: any(),
          reply_ref=make_ref() :: reference(),
          data_queue=[] :: [binary()]
        }).

-define(ACK_STREAM_TIMEOUT, timer:minutes(1)).

%% API
%%

-spec send_ack(pid(), pos_integer(), boolean()) -> ok.
send_ack(Pid, Seq, Reset) ->
    Pid ! {send_ack, Seq, Reset},
    ok.

%% libp2p_framed_stream
%%
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(server, Connection, [Path, AckModule, AckState | _]) ->
    libp2p_connection:set_idle_timeout(Connection, ?ACK_STREAM_TIMEOUT),
    Ref = AckModule:accept_stream(AckState, self(), Path),
    {ok, #state{connection=Connection, reply_ref=Ref,
                ack_module=AckModule, ack_state=AckState}};
init(client, Connection, [_Path, AckRef, AckModule, AckState | _]) ->
    libp2p_connection:set_idle_timeout(Connection, ?ACK_STREAM_TIMEOUT),
    {ok, #state{connection=Connection,
                ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}}.

handle_data(server, Data, State=#state{ack_ref=undefined}) ->
    %% queue it until we get our ack ref
    {noreply, State#state{data_queue=[Data|State#state.data_queue]}};
handle_data(_Kind, Data, State=#state{ack_ref=AckRef, ack_module=AckModule, ack_state=AckState}) ->
    case libp2p_ack_stream_pb:decode_msg(Data, libp2p_ack_frame_pb) of
        #libp2p_ack_frame_pb{messages=Bin, seqs=Seq} when Bin /= [] ->
            %% Inbound request to handle a message
            AckModule:handle_data(AckState, AckRef, lists:zip(Seq, Bin)),
            {noreply, State};
        #libp2p_ack_frame_pb{seqs=Seq, reset=Reset} ->
            %% When we receive an ack response from the remote side we
            %% call the handler to deal with it.
            AckModule:handle_ack(AckState, AckRef, Seq, Reset == true),
            {noreply, State};
        _Other ->
            lager:info("other ~p", [_Other]),
            {noreply, State}
    end.

handle_send(_Kind, From, Msgs, Timeout, State=#state{}) when is_list(Msgs) ->
    {Seqs, Data} = lists:unzip(Msgs),
    Msg = #libp2p_ack_frame_pb{messages=Data, seqs=Seqs},
    {ok, {reply, From, pending}, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{}};
handle_send(_Kind, From, {Data, Seq}, Timeout, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{messages=[Data], seqs=[Seq]},
    {ok, {reply, From, pending}, libp2p_ack_stream_pb:encode_msg(Msg), Timeout, State#state{}}.

handle_info(server, {Ref, AcceptResult}, State=#state{reply_ref=Ref}) ->
    case AcceptResult of
        {ok, AckRef} ->
            erlang:demonitor(Ref, [flush]),
            %% process any queued data in the order it was received
            NewState = State#state{ack_ref=AckRef, data_queue=[]},
            FinalState = lists:foldl(fun(Data, StateAcc) ->
                                             {noreply, NewStateAcc} = handle_data(server, Data, StateAcc),
                                             NewStateAcc
                                     end, NewState, lists:reverse(State#state.data_queue)),
            {noreply, FinalState};
        {error, too_many} ->
            {stop, normal, State};
        {error, Reason} ->
            lager:warning("Stopping on accept stream error: ~p", [Reason]),
            {stop, {error, Reason}, State}
    end;
handle_info(server, {'DOWN', Ref, process, _, Reason}, State=#state{reply_ref=Ref}) ->
    %% relcast server died while we were waiting for accept result
    {stop, Reason, State};
handle_info(_Kind, {send_ack, Seq, Reset}, State=#state{}) ->
    Msg = #libp2p_ack_frame_pb{seqs=Seq, reset=Reset},
    {noreply, State, libp2p_ack_stream_pb:encode_msg(Msg)}.
