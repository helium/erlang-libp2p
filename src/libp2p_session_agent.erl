-module(libp2p_session_agent).

-export([sessions/1]).

-callback sessions(pid()) -> [{libp2p_crypto:address(), libp2p_session:pid()}].

sessions(Pid) ->
    gen_server:call(Pid, sessions).
