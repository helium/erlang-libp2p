-module(stream_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-include("src/libp2p_yamux.hrl").

-record(state, {
          swarm1,
          swarm2,
          client,
          server,
          packet,
          inflight=0
         }).

-export([serve_stream/4,
         send_update_inflight/3, send_update_packet/3,
         recv_update_inflight/2]).
-export([initial_state/0, prop_correct/0]).

-export([send/2,
         send_pre/1,
         send_args/1,
         send_post/3,
         send_next/3]).

-export([recv/2,
         recv_pre/1,
         recv_args/1,
         recv_post/3,
         recv_next/3]).


initial_state() ->
    #state{swarm1={var, swarm1}, swarm2={var, swarm2}, client={var, client}, server={var, server}, packet={var, packet}}.

serve_stream(Connection, _Path, _TID, [Parent]) ->
    Parent ! {hello, self()},
    serve_loop(Connection, Parent).

serve_loop(Connection, Parent) ->
    receive
        {recv, N} ->
            Result = libp2p_connection:recv(Connection, N, 100),
            Parent ! {recv, N, Result},
            serve_loop(Connection, Parent);
         stop ->
            libp2p_connection:close(Connection),
            ok
    end.

send_pre(_S) ->
    true.

send_args(S) ->
    [?SUCHTHAT(Size, eqc_gen:oneof([eqc_gen:int(), eqc_gen:largeint()]), Size > 0),
    S].

send(Size0, S) ->
    Size = min(byte_size(S#state.packet), Size0),
    <<Data:Size/binary, Rest/binary>> = S#state.packet,
    {catch libp2p_connection:send(S#state.client, Data, 100), Rest}.

send_post(S, [Size0, _], {Result, _}) ->
    Size = min(byte_size(S#state.packet), Size0),
    case Size + S#state.inflight > ?DEFAULT_MAX_WINDOW_SIZE of
        true ->
            case Result of
                {error, timeout} -> true;
                _ -> expected_timeout
            end;
        false ->
            eqc_statem:eq(Result, ok)
    end.

send_next(S, _Result, [Size, _]) ->
    S#state{inflight={call, ?MODULE, send_update_inflight, [Size, S#state.inflight, S#state.packet]},
            packet={call, ?MODULE, send_update_packet, [Size, S#state.inflight, S#state.packet]}}.

send_update_inflight(Size0, Inflight, Packet) ->
    Size = min(Size0, byte_size(Packet)),
    case Size + Inflight > ?DEFAULT_MAX_WINDOW_SIZE of
        true -> ?DEFAULT_MAX_WINDOW_SIZE;
        false -> Inflight + Size
    end.

send_update_packet(Size0, Inflight, Packet) ->
    Size = min(Size0, byte_size(Packet)),
    case Size + Inflight > ?DEFAULT_MAX_WINDOW_SIZE of
        true ->
            Start = min(byte_size(Packet), ?DEFAULT_MAX_WINDOW_SIZE - Inflight),
            Length = byte_size(Packet) - Start;
        false ->
            Start = min(byte_size(Packet), Size),
            Length = byte_size(Packet) - Start
    end,
    binary:part(Packet, Start, Length).


recv_pre(_S) ->
    true.

recv_args(S) ->
    [?SUCHTHAT(Size, eqc_gen:oneof([eqc_gen:int(), eqc_gen:largeint()]), Size > 0),
     S].

recv(Size, S) ->
    Server = S#state.server,
    Server ! {recv, Size},
    receive
        {recv, Size, Result} -> Result;
        {'DOWN', _, _, Server, Error} -> Error
    end.

recv_post(S, [Size, _], Result) ->
    case Size > S#state.inflight of
        true -> eqc_statem:eq(Result, {error, timeout});
        false -> eqc_statem:eq(element(1, Result), ok)
    end.

recv_next(S, _Result, [Size, _]) ->
    S#state{inflight={call, ?MODULE, recv_update_inflight, [Size, S#state.inflight]}}.

recv_update_inflight(Size, Inflight) ->
    case Size > Inflight of
        true -> Inflight;
        false -> Inflight - Size
    end.



prop_correct() ->
%   with_parameter(print_counterexample, false,
                   ?FORALL({Packet, Cmds},
                           {eqc_gen:largebinary(500000), noshrink(commands(?MODULE))},
                           begin
                               application:ensure_all_started(ranch),
                               application:ensure_all_started(lager),
                               lager:set_loglevel(lager_console_backend, debug),
                               Swarm1 = libp2p_swarm:start(0),
                               Swarm2 = libp2p_swarm:start(0),
                               ok = libp2p_swarm:add_stream_handler(Swarm2, "eqc", {?MODULE, serve_stream, [self()]}),

                               [S2Addr] = libp2p_swarm:listen_addrs(Swarm2),
                               {ok, StreamClient} = libp2p_swarm:dial(Swarm1, S2Addr, "eqc"),
                               StreamServer = receive
                                                  {hello, Server} -> Server
                                              end,
                               erlang:monitor(process, StreamServer),
                               {H, S0, Res} = run_commands(?MODULE, Cmds, [{swarm1, Swarm1},
                                                                           {swarm2, Swarm2},
                                                                           {client, StreamClient},
                                                                           {server, StreamServer},
                                                                           {packet, Packet}]),
                               S = eqc_symbolic:eval(S0),
                               ServerAlive = erlang:is_process_alive(StreamServer),
                               libp2p_connection:close(StreamClient),
                               libp2p_swarm:stop(Swarm1),
                               libp2p_swarm:stop(Swarm2),
                               pretty_commands(?MODULE, Cmds, {H, S, Res},
                                               aggregate(command_names(Cmds),
                                                         ?WHENFAIL(
                                                            begin
                                                                eqc:format("packet size: ~p~n", [byte_size(S#state.packet)]),
                                                                eqc:format("state ~p~n", [S#state{packet= <<>>}])
                                                            end,
                                                            conjunction([{server, eqc:equals(ServerAlive, true)}, {result, eqc:equals(Res, ok)}]))))
                           end).


