-module(group_relcast_SUITE).

-export([all/0]).
-export([restart_test/1]).

all() ->
    [restart_test].


restart_test(_Config) ->
    %% Restarting a relcast group should resend outbound messages that
    %% were not acknowledged, and re-deliver inbould messages to the
    %% handler.
    ok.
