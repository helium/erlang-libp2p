-module(libp2p_transport_tcp_listen_sup).

-behaviour(supervisor).

%% API
-export([start_link/3,
         listen_addrs/1
         ]).

%% Private
-export([accept_pool/1]).
%% Supervisor
-export([init/1]).

-define(LISTEN_SOCKET_ID, listen_socket).
-define(POOL_ID, pool).

%% API
%%

-spec start_link(inet:ip_address(), inet:port_number(), Opts::map()) -> {ok, pid()} | {error, term()}.
start_link(IP, Port, Opts) ->
    supervisor:start_link(?MODULE, [IP, Port, Opts]).

-spec listen_addrs(Sup::pid()) -> [{inet:ip_address(), inet:port_number()}].
listen_addrs(Sup) ->
    Children = supervisor:which_children(Sup),
    {?LISTEN_SOCKET_ID, Pid, _, _} = lists:keyfind(?LISTEN_SOCKET_ID, 1, Children),
    libp2p_transport_tcp_listen_socket:listen_addrs(Pid).


%% Private
%%

-spec accept_pool(pid()) -> Pool::pid().
accept_pool(Sup) ->
    Children = supervisor:which_children(Sup),
    {?POOL_ID, Pid, _, _} = lists:keyfind(?POOL_ID, 1, Children),
    Pid.


init([_IP, _Port, Opts]=ListenArgs) ->
    Flags = #{strategy => rest_for_one},
    Pool = #{id => ?POOL_ID,
             start => {libp2p_transport_tcp_accept_pool, start_link, [Opts]}},
    Socket = #{id => ?LISTEN_SOCKET_ID,
               start => {libp2p_transport_tcp_listen_socket, start_link, [self() | ListenArgs]}},
{ok, {Flags, [Pool, Socket]}}.
