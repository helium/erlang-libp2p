-module(libp2p_transport_tcp).

-behaviour(libp2p_connection).

-export([new_listener/3, dial/1, send/2, recv/2, acknowledge/2, set_options/2, close/1]).

-record(tcp_state, {
          socket :: gen_tcp:socket(), 
          transport :: atom()
         }).

-spec new_listener(multiaddr:multiaddr(), any(), atom()) -> reference() | {error, term()}.
new_listener(MAddr, Options, ProtocolModule) ->
    case tcp_addr(MAddr, Options) of
        {_Address, Port, Options} ->
            Ref = make_ref(),
            case ranch:start_listener(Ref,
                                      ranch_tcp, [{port, Port} | Options],
                                      libp2p_transport_tcp_protocol, 
                                      [{protocol_module, ProtocolModule}]) of
                {ok, _} -> Ref;
                Error -> Error
            end
    end.


-spec dial(multiaddr:multiaddr()) -> libp2p_connection:connection() | {error, term()}.
dial(MAddr) ->
    case tcp_addr(MAddr, []) of
        {Address, Port, Options} -> 
            {ok, Socket} = gen_tcp:connect(Address, Port, Options),
            libp2p_connection:new(?MODULE, #tcp_state{socket=Socket, transport=ranch_tcp});
        Error -> Error
    end.


tcp_addr(MAddr, Options) when is_binary(MAddr) ->
    tcp_addr(multiaddr:protocols(MAddr), Options);
tcp_addr(Protocols=[{AddrType, Address}, {"tcp", PortStr}], Options) ->
    Port = list_to_integer(PortStr),
    case AddrType of
        "ip4" -> {Address, Port, [inet | Options]};
        "ip6" -> {Address, Port, [inet6 | Options]};
        _ -> {error, {unsupported_address, Protocols}}
    end;
tcp_addr(Protocols, _Options) ->
    {error, {unsupported_address, Protocols}}.


%%
%% libp2p_connection
%%

-spec send(any(), iodata()) -> ok | {error, term()}.
send(#tcp_state{socket=Socket, transport=Transport}, Data) ->
    Transport:send(Socket, Data).

-spec recv(any(), non_neg_integer()) -> binary() | {error, term()}.
recv(#tcp_state{socket=Socket, transport=Transport}, Length) ->
    Transport:recv(Socket, Length).

-spec close(any()) -> ok.
close(#tcp_state{socket=Socket, transport=Transport}) ->
    Transport:close(Socket).

-spec acknowledge(any(), reference()) -> ok.
acknowledge(#tcp_state{}, Ref) ->
    ranch:accept_ack(Ref).

-spec set_options(any(), any()) -> ok | {error, term()}.
set_options(#tcp_state{socket=Socket}, Options) ->
    inet:setopts(Socket, Options).
