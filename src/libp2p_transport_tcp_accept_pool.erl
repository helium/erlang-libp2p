-module(libp2p_transport_tcp_accept_pool).

-behavior(acceptor_pool).

%% API
-export([start_link/1, accept_socket/3]).
%% acceptor_pool
-export([init/1]).

start_link(Opts) ->
    acceptor_pool:start_link(?MODULE, Opts).

accept_socket(Pool, Socket, Acceptors) ->
    acceptor_pool:accept_socket(Pool, Socket, Acceptors).

init(Opts) ->
    Conn = #{id => libp2p_stream_tcp,
             start => {libp2p_stream_tcp, Opts, []},
             grace => 5000}, % Give connections 5000ms to close before shutdown
    {ok, {#{}, [Conn]}}.
