-module(libp2p_transport_tcp_listen_socket).



-behaviour(gen_server).

%% public api

-export([start_link/4,
        listen_addrs/1,
         get_non_local_addrs/0]).

%% gen_server api

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-define(DEFAULT_MAX_INBOUND_CONNECTIONS, 100).


%% AP
start_link(Sup, IP, Port, Opts) ->
    gen_server:start_link(?MODULE, {Sup, IP, Port, Opts}, []).

-spec listen_addrs(pid()) -> [{inet:ip_address(), inet:port_number()}].
listen_addrs(Pid) ->
    gen_server:call(Pid, listen_addrs, infinity).

%% gen_server api

-spec init({Sup::pid(), IP::inet:ip_address(), Port::inet:port_number(), Opts::map()})
          -> {ok, term()} | {stop, term()}.
init({Sup, IP, Port, #{cache_dir := CacheDir}}) ->
    % Trapping exit so can close socket and dets table in terminate/2
    _ = process_flag(trap_exit, true),
    Filename = string:replace(string:slice(libp2p_transport_tcp:to_multiaddr({IP, Port}), 1) ++ ".cache",
                              "/", "_", all),
    CacheFile = filename:join([CacheDir, lists:flatten(Filename)]),
    {ok, CacheName} = dets:open_file(make_ref(), [{file, CacheFile}]),
    ReusedPort = reuseport0(CacheName, IP, Port),
    ListenOptions = listen_options(IP),
    case gen_tcp:listen(ReusedPort, ListenOptions) of
        {ok, Socket} ->
            ListenAddrs = listen_addresses(Socket),
            dets:insert(CacheName, {{listen_addrs, ip_address_type(IP)}, ListenAddrs}),
            dets:close(CacheName),
            % acceptor could close the socket if there is a problem
            MRef = monitor(port, Socket),
            self () ! {register_socket, Sup},
            {ok, {Socket, MRef}};
        {error, Reason} ->
            dets:close(CacheName),
            {stop, Reason}
    end.

handle_call(listen_addrs, _, State={Socket, _}) ->
    {reply, listen_addresses(Socket), State};
handle_call(_, _, State) ->
    {reply, ok, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({register_socket, Sup}, State={Socket, _MRef}) ->
    Pool = libp2p_transport_tcp_listen_sup:accept_pool(Sup),
    libp2p_transport_tcp_accept_pool:accept_socket(Pool, Socket, ?DEFAULT_MAX_INBOUND_CONNECTIONS),
    {noreply, State};
handle_info({'DOWN', MRef, port, Socket, Reason}, {Socket, MRef} = State) ->
    {stop, Reason, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, {Socket, MRef}) ->
    % Socket may already be down but need to ensure it is closed to avoid
    % eaddrinuse error on restart
    case demonitor(MRef, [flush, info]) of
        true  -> gen_tcp:close(Socket);
        false -> ok
    end.


%%
%% Utilities
%%

-spec listen_options(inet:ip_address()) -> [gen_tcp:listen_option()].
listen_options(IP) ->
    InetOpts = case ip_address_type(IP) of
                   inet6 -> [inet6, {ipv6_v6only, true}];
                   _ -> [inet]
               end,
    InetOpts ++
        [
          {ip, IP},
          {backlog, 1024},
          {nodelay, true},
          {send_timeout, 30000},
          {send_timeout_close, true},
          {reuseaddr, true},
          binary,
          {active, false},
          {packet, raw},
          libp2p_transport_tcp:reuseport_raw_option()
        ].

-spec listen_addresses(gen_tcp:socket()) -> [{inet:ip_address(), inet:port_number()}].
listen_addresses(Socket) ->
    {ok, SockAddr={IP, Port}} = inet:sockname(Socket),
    %%% check if IP address is all 0
    case lists:all(fun(D) -> D == 0 end, tuple_to_list(IP)) of
        false ->
            %% A normal IP address, return just the address, with any
            %% nap map applied
            [libp2p_nat:maybe_apply_nat_map(SockAddr)];
        true ->
            % all 0 address, collect all non loopback interface addresses
            Addresses = get_non_local_addrs(),
            %% And apply any nat map to each address (of the same size)
            [libp2p_nat:maybe_apply_nat_map({Addr, Port})
                || Addr <- Addresses, size(Addr) == size(IP)]
    end.

get_non_local_addrs() ->
    {ok, IFAddrs} = inet:getifaddrs(),
    [Addr ||
        {_, Opts} <- IFAddrs,
        {addr, Addr} <- Opts,
        {flags, Flags} <- Opts,
        %% filter out loopbacks
        not lists:member(loopback, Flags),
        %% filter out ipv6 link-local addresses
        not (filter_ipv6(Addr)),
        %% filter out RFC3927 ipv4 link-local addresses
        not (filter_ipv4(Addr))
    ].

filter_ipv4(Addr) ->
    erlang:size(Addr) == 4
        andalso erlang:element(1, Addr) == 169
        andalso erlang:element(2, Addr) == 254.

filter_ipv6(Addr) ->
    erlang:size(Addr) == 8
        andalso erlang:element(1, Addr) == 16#fe80.

ip_address_type(IP) ->
    case size(IP) of
        4 -> inet;
        8 -> inet6
    end.

-spec reuseport0(dets:tab_name(), inet:ip_address(), inet:port_number()) -> inet:port_number().
reuseport0(CacheName, IP, 0) when IP == {0,0,0,0} orelse
                                  IP == {0,0,0,0,0,0,0,0} ->
    case dets:lookup(CacheName, {listen_addrs, ip_address_type(IP)}) of
        [] -> 0;
        [{_, ListenAddrs} | _] ->
            Ports = [P ||  {_, P} <- ListenAddrs],
            [P1|_] = Ports,
            Filtered = lists:filter(fun(P) -> P =:= P1 end, Ports),
            case erlang:length(Filtered) =:= erlang:length(ListenAddrs) of
                true -> P1;
                false -> 0
            end
    end;
reuseport0(CacheName, IP, 0) ->
    case dets:lookup(CacheName, {listen_addrs, ip_address_type(IP)}) of
        [] -> 0;
        [{_, ListenAddrs} | _] ->
            lists:foldl(
                fun({StoredIP, Port}, 0) when StoredIP == IP ->
                        Port;
                   ({_, _}, 0) ->
                        0;
                   (_, Port) ->
                        Port
                end, 0, ListenAddrs)
    end;
reuseport0(_CacheName, _IP, Port) ->
    Port.
