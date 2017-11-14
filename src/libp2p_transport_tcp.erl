-module(libp2p_transport_tcp).

-behaviour(libp2p_connection).

-export([new_listener/3, new_connection/1, dial/1, send/2, recv/3, acknowledge/2, set_options/2, close/1]).

-record(tcp_state, {
          socket :: gen_tcp:socket(), 
          transport :: atom()
         }).

-type state() :: #tcp_state{}.

-spec new_listener(multiaddr:multiaddr() | string(), atom(), any()) -> reference() | {error, term()}.
new_listener(MAddr, ProtocolModule, ProtocolOptions) when is_list(MAddr) ->
    new_listener(multiaddr:new(MAddr), ProtocolModule, ProtocolOptions);
new_listener(MAddr, ProtocolModule, ProtocolOptions) ->
    case tcp_addr(MAddr) of
        {_Address, Port, Options} ->
            Ref = make_ref(),
            Opts = [{protocol_module, ProtocolModule},
                    {protocol_opts, ProtocolOptions} ],
            case ranch:start_listener(Ref,
                                      ranch_tcp, [{port, Port} | Options],
                                      libp2p_transport_tcp_protocol, Opts) of
                {ok, _} -> Ref;
                Error -> Error
            end
    end.

-spec new_connection(gen_tcp:socket()) -> libp2p_connection:connection().
new_connection(Socket) ->
    libp2p_connection:new(?MODULE, #tcp_state{socket=Socket, transport=ranch_tcp}).

-spec dial(multiaddr:multiaddr() | string()) -> libp2p_connection:connection() | {error, term()}.
dial(MAddr) when is_list(MAddr) ->
    dial(multiaddr:new(MAddr));
dial(MAddr) ->
    case tcp_addr(MAddr) of
        {Address, Port, Options} -> 
            {ok, Socket} = gen_tcp:connect(Address, Port, Options),
            new_connection(Socket);
        Error -> Error
    end.


tcp_addr(MAddr) when is_binary(MAddr) ->
    tcp_addr(multiaddr:protocols(MAddr));
tcp_addr(Protocols=[{AddrType, Address}, {"tcp", PortStr}]) ->
    Port = list_to_integer(PortStr),
    case AddrType of
        "ip4" -> {Address, Port, [inet, binary, {active, false}]};
        "ip6" -> {Address, Port, [inet6, binary, {active, false}]};
        _ -> {error, {unsupported_address, Protocols}}
    end;
tcp_addr(Protocols) ->
    {error, {unsupported_address, Protocols}}.


%%
%% libp2p_connection
%%

-spec send(state(), iodata()) -> ok | {error, term()}.
send(#tcp_state{socket=Socket, transport=Transport}, Data) ->
    Transport:send(Socket, Data).

-spec recv(state(), non_neg_integer(), pos_integer()) -> binary() | {error, term()}.
recv(#tcp_state{socket=Socket, transport=Transport}, Length, Timeout) ->
    case Transport:recv(Socket, Length, Timeout) of
        {ok, Data} -> Data;
        Error -> Error
    end.

-spec close(state()) -> ok.
close(#tcp_state{socket=Socket, transport=Transport}) ->
    Transport:close(Socket).

-spec acknowledge(state(), reference()) -> ok.
acknowledge(#tcp_state{}, Ref) ->
    ranch:accept_ack(Ref).

-spec set_options(state(), any()) -> ok | {error, term()}.
set_options(#tcp_state{socket=Socket, transport=Transport}, Options) ->
    Transport:setopts(Socket, Options).
