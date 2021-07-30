-module(libp2p_transport_tcp).

-behaviour(libp2p_connection).

-export([start_listener/3, new_connection/1, dial/1]).

% libp2p_onnection
-export([send/3, recv/3, acknowledge/2, addr_info/1,
         close/1, controlling_process/2,
         fdset/1, fdclr/1
        ]).

-record(tcp_state, {
          socket :: gen_tcp:socket(),
          transport :: atom()
         }).

-type state() :: #tcp_state{}.

-spec start_listener(supervisor:pid(), string(), ets:tab())
                    -> {ok, [string()], pid()} | {error, term()}.
start_listener(Sup, Addr, TID) ->
    case tcp_addr(Addr) of
        {Address, Port, Options} ->
            SocketOpts = [{ip, Address}, {active, false}, binary | Options],
            case gen_tcp:listen(Port, SocketOpts) of
                {ok, Socket} ->
                    ListenAddrs = tcp_listen_addrs(Socket),
                    ProtocolOpts = {?MODULE, TID},
                    ChildSpec = ranch:child_spec(ListenAddrs, ranch_tcp, [{socket, Socket}],
                                                 libp2p_transport_ranch_protocol, ProtocolOpts),
                    {ok, Pid} = supervisor:start_child(Sup, ChildSpec),
                    ok = gen_tcp:controlling_process(Socket, Pid),
                    {ok, ListenAddrs, Pid};
                {error, Reason} -> {error, Reason}
            end;
        {error, Error} -> {error, Error}
    end.

-spec new_connection(inet:socket()) -> libp2p_connection:connection().
new_connection(Socket) ->
    libp2p_connection:new(?MODULE, #tcp_state{socket=Socket, transport=ranch_tcp}).

-spec dial(string()) -> {ok, libp2p_connection:connection()} | {error, term()}.
dial(MAddr) ->
    case tcp_addr(MAddr) of
        {Address, Port, Options} ->
            case gen_tcp:connect(Address, Port, [binary, {active, false} | Options]) of
                {ok, Socket} -> {ok, new_connection(Socket)};
                {error, Error} -> {error, Error}
            end;
        {error, Reason} -> {error, Reason}
    end.

tcp_listen_addrs(Socket) ->
    {ok, SockAddr={IP, Port}} = inet:sockname(Socket),
    case lists:all(fun(D) -> D == 0 end, tuple_to_list(IP)) of
        false ->
            [multiaddr(SockAddr)];
        true ->
            % all 0 address, collect all non loopback interface addresses
            {ok, IFAddrs} = inet:getifaddrs(),
            [multiaddr({Addr, Port}) ||
                {_, Opts} <- IFAddrs, {addr, Addr} <- Opts, {flags, Flags} <- Opts,
                size(Addr) == size(IP),
                not lists:member(loopback, Flags),
                %% filter out ipv6 link-local addresses
                not (size(Addr) == 8 andalso element(1, Addr) == 16#fe80)
            ]
    end.


-spec tcp_addr(string()) -> {inet:ip_address(), non_neg_integer(), [gen_tcp:listen_option()]} | {error, term()}.
tcp_addr(MAddr) when is_list(MAddr) ->
    tcp_addr(MAddr, multiaddr:protocols(multiaddr:new(MAddr))).

tcp_addr(Addr, [{AddrType, Address}, {"tcp", PortStr}]) ->
    Port = list_to_integer(PortStr),
    case AddrType of
        "ip4" ->
            {ok, IP} = inet:parse_ipv4_address(Address),
            {IP, Port, [inet]};
        "ip6" ->
            {ok, IP} = inet:parse_ipv6_address(Address),
            {IP, Port, [inet6]};
        _ -> {error, {unsupported_address, Addr}}
    end;
tcp_addr(Addr, _Protocols) ->
    {error, {unsupported_address, Addr}}.


multiaddr({IP, Port}) when is_tuple(IP) andalso is_integer(Port) ->
    Prefix  = case size(IP) of
                  4 -> "/ip4";
                  8 -> "/ip6"
              end,
    lists:flatten(io_lib:format("~s/~s/tcp/~b", [Prefix, inet:ntoa(IP), Port ])).

%%
%% libp2p_connection
%%

-spec send(state(), iodata(), non_neg_integer()) -> ok | {error, term()}.
send(#tcp_state{socket=Socket, transport=Transport}, Data, _Timeout) ->
    %% TODO: Re-enable this
    %% Transport:setopts(Socket, [{send_timeout, Timeout}]),
    Transport:send(Socket, Data).

-spec recv(state(), non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, term()}.
recv(#tcp_state{socket=Socket, transport=Transport}, Length, Timeout) ->
    Transport:recv(Socket, Length, Timeout).

-spec close(state()) -> ok.
close(#tcp_state{socket=Socket, transport=Transport}) ->
    Transport:close(Socket).

-spec acknowledge(state(), reference()) -> ok.
acknowledge(#tcp_state{}, Ref) ->
    ranch:accept_ack(Ref).

-spec fdset(state()) -> ok | {error, term()}.
fdset(#tcp_state{socket=Socket}) ->
    case inet:getfd(Socket) of
        {error, Error} -> {error, Error};
        {ok, FD} -> inert:fdset(FD)
    end.

-spec fdclr(state()) -> ok.
fdclr(#tcp_state{socket=Socket}) ->
    case inet:getfd(Socket) of
        {error, Error} -> {error, Error};
        {ok, FD} -> inert:fdclr(FD)
    end.

-spec addr_info(state()) -> {string(), string()}.
addr_info(#tcp_state{socket=Socket}) ->
    {ok, LocalAddr} = inet:sockname(Socket),
    {ok, RemoteAddr} = inet:peername(Socket),
    {multiaddr(LocalAddr), multiaddr(RemoteAddr)}.


-spec controlling_process(state(), pid()) ->  ok | {error, closed | not_owner | atom()}.
controlling_process(#tcp_state{socket=Socket}, Pid) ->
    gen_tcp:controlling_process(Socket, Pid).
