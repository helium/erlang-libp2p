-module(libp2p_stream_multistream).

-behavior(libp2p_stream).

-type prefix() :: string().
-type path_handler() :: {Module::atom(), Opts::map()}.
-type handler() :: {prefix(), path_handler()}.
-type handlers() :: [handler()].

-export_type([handler/0, handlers/0]).

-type fsm_msg() :: {packet, Packet::binary()} | {command, Cnd::any()} | {error, Error::term()}.
-type fsm_result() ::
        {keep_state, Data::any()} |
        {keep_state, Data::any(), libp2p_stream:actions()} |
        {next_state, State::atom(), Data::any()} |
        {next_state, State::atom(), Data::any(), libp2p_stream:actions()} |
        {close, Reason::term()} |
        {close, Reason::term(), libp2p_stream:actions()}.

-record(state, {
                handlers=[] :: handlers(),
                fsm_state :: atom(),
                selected_handler=1 :: pos_integer()
               }).

-define(PROTOCOL,"/multistream/1.0.0").
-define(NEGOTIATION_TIME, 30000).
-define(MAX_LINE_LENGTH, 64 * 1024).

%% libp2p_stream
-export([init/2, handle_packet/4, handle_command/3, handle_info/3]).
%% FSM states
-export([handshake/3, handshake_reverse/3, negotiate/3]).
%% Utility
-export([line_to_binary/1, lines_to_binary/1, binary_to_line/1, binary_to_lines/1]).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.

init(server, #{handlers := Handlers}) ->
    {ok, #state{fsm_state=handshake, handlers=Handlers},
     [{packet_spec, [varint]},
      {send, <<?PROTOCOL>>},
      {timer, negotiate_timeout, ?NEGOTIATION_TIME}]};
init(client, #{handlers := Handlers}) ->
    {ok, #state{fsm_state=handshake, handlers=Handlers},
     [{packet_spec, [varint]},
      {timer, handshake_timeout, rand:uniform(20000) + 15000}]};
init(_, _) ->
    {stop, missing_handlers}.




%%
%% FSM functions
%%

-spec handshake(libp2p_stream:kind(), fsm_msg(), #state{}) -> fsm_result().
handshake(client, {packet, Packet}, Data=#state{handlers=Handlers}) ->
    case binary_to_line(Packet) of
        {?PROTOCOL, _} ->
            %% Handshake success. Request the first handler in handler
            %% list and move on to negotiation state.
            case select_handler(1, Data) of
                not_found ->
                    handshake(client, {error, no_handlers}, Data);
                {Key, _} ->
                    lager:debug("Client negotiating handler using: ~p", [K || {K, _} <- Handlers]),
                    {next_state, negotiate, Data#state{selected_handler=1},
                     {[{cancel_timer, handshake_timeout},
                       {send, <<?PROTOCOL>>},
                       {send, list_to_binary(Key)}]}}
            end;
        Other ->
            handshake(client, {error, {handshake_mismatch, Other}}, Data)
    end;
handshake(client, {error, handshake_timeout}, Data=#state{}) ->
    %% The client failed to receive a handshake from the server. This
    %% _may_ happen if there's a simultaneous connection that happens
    %% where two nodes connect to eachother at the same time which
    %% bypasses the listen socket.Port reuse causes this corner case
    %% of tcp behavior.
    %%
    %% We verify this happened by having the client send the
    %% handshake.If it receives a response it means this client should
    %% behave like a server instead.
    {next_state, handshake_reverse, Data,
    [{send, <<?PROTOCOL>>}]};
handshake(client, {error, Error}, #state{}) ->
    lager:notice("Client handshake failed: ~p", [Error]),
    {close, {error, Error}};
handshake(Kind, Msg, State) ->
    handle_event(Kind, Msg, State).


-spec handshake_reverse(libp2p_stream:kind(), fsm_msg(), #state{}) -> fsm_result().
handshake_reverse(client, {packet, Packet}, Data=#state{}) ->
    case binary_to_line(Packet) of
        {?PROTOCOL, _} ->
            %% We received a handshake that we initiated, which is
            %% usually server beavior. This likely means that we're in
            %% the simultaneouso connection scenario as described in
            %% `handshake'. We send the handshake response and reverse
            %% our `kind' to start behaving like a server post
            %% handshake.
            {next_state, negotiate, Data,
             [{send, <<?PROTOCOL>>},
              swap_kind,
              {timer, negotiate_timeout, ?NEGOTIATION_TIME}]};
        Other ->
            handshake_reverse(client, {error, {handshake_mismatch, Other}}, Data)
    end;
handshake_reverse(client, {error, Error}, #state{}) ->
    lager:notice("Client reverse handshake failed: ~p", [Error]),
    {close, {error, Error}};
handshake_reverse(Kind, Msg, State) ->
    handle_event(Kind, Msg, State).

-spec negotiate(libp2p_stream:kind(), fsm_msg(), #state{}) -> fsm_result().
negotiate(client, {packet, Packet}, Data=#state{}) ->
    %% Response from a request to the "selected" handler attempt.
    case binary_to_line(Packet) of
        {"na", _} ->
            %% select the next handler past selected, if there are any
            NextHandler = Data#state.selected_handler + 1,
            case select_handler(NextHandler, Data) of
                not_found ->
                    negotiate(client, {error, no_handlers}, Data);
                {Key, _} ->
                    lager:debug("Client negotiating next handler: ~p", [Key]),
                    {keep_state, Data#state{selected_handler=NextHandler},
                     {[{cancel_timer, handshake_timeout},
                       {send, list_to_binary(Key)}]}}
            end;
        {Line, _} ->
            %% Server agreed and switched to the handler.
            case select_handler(Data#state.selected_handler, Data) of
                {Line, {M, A}} ->
                    lager:debug("Client negotiated handler for: ~p, handler: ~p", [Line, M]),
                    {keep_state, Data, [{swap, M, A}]};
                _ ->
                    lager:debug("Client got unexpected server response during negotiation: ~p", [Line]),
                    {stop, {error, protocol_error}}
            end
    end;
negotiate(client, {error, Error}, #state{}) ->
    lager:notice("Client negotiation failed: ~p", [Error]),
    {stop, {error, Error}};

negotiate(server, {packet, Packet}, Data=#state{}) ->
    case binary_to_line(Packet) of
        {"ls", _} ->
            Keys = [Key || {Key, _} <- Data#state.handlers],
            {keep_state, Data,
             [{send, lines_to_binary(Keys)}]};
        {Line, _} ->
            case find_handler(Line, Data#state.handlers) of
                not_found ->
                    {keep_state, Data,
                     [{send, <<"na">>}]};
                {_Prefix, {M, O}, LineRest} ->
                    lager:debug("Server negotiated handler for: ~p, handler: ~p, path: ~p",
                                [Line, M, LineRest]),
                    {keep_state, Data,
                     [{send, list_to_binary(Line)}],
                     [{swap, M, O#{path => LineRest}}]
                    }
            end
    end;
negotiate(server, {error, Error}, #state{}) ->
    lager:notice("Server negotiation failed for: ~p", [Error]),
    {stop, {error, Error}};

negotiate(Kind, Msg, State) ->
    handle_event(Kind, Msg, State).


%%
%% FSM implementation
%%

handle_message(Kind, Msg, Data0=#state{fsm_state=State}) ->
    try
        case erlang:apply(?MODULE, State, [Kind, Msg, Data0]) of
            {keep_state, Data} -> {ok,Data};
            {keep_state, Data, Actions} -> {ok, Data, Actions};
            {next_state, NextState, Data} -> {ok, Data#state{fsm_state=NextState}};
            {next_state, NextState, Data, Actions} -> {ok, Data#state{fsm_state=NextState}, Actions};
            {stop, Reason} -> {stop, Reason};
            {stop, Reason, Actions} -> {stop, Reason, Actions}
        end
    catch
        What:Why:Who ->
            {stop, {What, Why, Who}}
    end.


handle_packet(Kind, _Header, Packet, Data=#state{}) ->
    handle_message(Kind, {packet, Packet}, Data).

handle_command(Kind, Command, Data=#state{}) ->
    handle_message(Kind, {command, Command}, Data).

handle_info(Kind, Msg, Data=#state{}) ->
    handle_message(Kind, Msg, Data).


%%
%% Utilities
%%

handle_event(server, {error, negotiate_timeout}, #state{}) ->
    lager:notice("Server timeout negotiating with client"),
    {close, normal};

handle_event(Kind, Msg, _State) ->
    lager:warning("Unhandled message (~p): ~p", [Kind, Msg]),
    keep_state.

select_handler(Index, #state{handlers=Handlers}) when Index =< length(Handlers)->
    lists:nth(Index, Handlers);
select_handler(_Index, #state{}) ->
    not_found.

line_to_binary(Line) when is_list(Line) ->
    line_to_binary(list_to_binary(Line));
line_to_binary(Line) when byte_size(Line) > ?MAX_LINE_LENGTH ->
    erlang:error({max_line, byte_size(Line)});
line_to_binary(Line) ->
    LineSize = libp2p_packet:encode_varint(byte_size(Line) + 1),
    <<LineSize/binary, Line/binary, $\n>>.

lines_to_binary(Lines) when is_list(Lines) ->
    EncodedLines = lists:foldr(fun(L, Acc) ->
                                       <<(line_to_binary(L))/binary, Acc/binary>>
                               end, <<>>, Lines),
    EncodedCount = libp2p_packet:encode_varint(length(Lines)),
    <<EncodedCount/binary, EncodedLines/binary>>.

-spec binary_to_lines(binary()) -> [string()].
binary_to_lines(Bin) ->
    {Count, Data} = libp2p_packet:decode_varint(Bin),
    binary_to_lines(Data, Count, []).

-spec binary_to_lines(binary(), non_neg_integer(), list()) -> [string()].
binary_to_lines(_Bin, 0, Acc) ->
    lists:reverse(Acc);
binary_to_lines(Bin, Count, Acc) ->
    {Line, Rest} = binary_to_line(Bin),
    binary_to_lines(Rest, Count-1, [Line | Acc]).

-spec binary_to_line(binary()) -> {list(), binary()}.
binary_to_line(Bin) ->
    case libp2p_packet:decode_varint(Bin) of
        {Size, _} when Size > ?MAX_LINE_LENGTH ->
            erlang:error({max_line, Size});
        {Size, Rest}->
            DataSize = Size - 1,
            case Rest of
                <<Data:DataSize/binary, $\n, Tail/binary>> ->
                    {binary_to_list(Data), Tail};
                _ ->
                    erlang:error({invalid_line, Bin})
            end
    end.

-spec find_handler(string(), handlers()) ->
                          {Prefix::string(), PathHandler::path_handler(), Rest::string()} | not_found.
find_handler(_Line, []) ->
    not_found;
find_handler(Line, [{Prefix, Handler} | Handlers]) ->
    case string:prefix(Line, Prefix) of
        nomatch -> find_handler(Line, Handlers);
        Rest -> {Prefix, Handler, Rest}
    end.


-ifdef(TEST).

line_test() ->
    Line = "test-stream/1.0.0/path",
    Encoded = line_to_binary(Line),

    ?assertEqual({Line, <<>>}, binary_to_line(Encoded)),
    ?assertError({invalid_line, _},
                 binary_to_line(binary_part(Encoded, 0, byte_size(Encoded) - 1))),

    MaxLineSize = ?MAX_LINE_LENGTH + 1,
    MaxLine = crypto:strong_rand_bytes(MaxLineSize),
    ?assertError({max_line, MaxLineSize}, line_to_binary(MaxLine)),

    MaxBin = <<(libp2p_packet:encode_varint(?MAX_LINE_LENGTH+1))/binary>>,
    ?assertError({max_line, MaxLineSize}, binary_to_line(MaxBin)),

    ok.

lines_test() ->
    Lines = [
             "stream/1.0.0/path",
             "foo/1.0.0/path"
             "bar/1.0.0/path"
            ],
    Encoded = lines_to_binary(Lines),

    ?assertEqual(Lines, binary_to_lines(Encoded)),
    ?assertError({invalid_line, _},
                 binary_to_lines(binary_part(Encoded, 1, byte_size(Encoded) - 1))),

    ok.

-endif.
