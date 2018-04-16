-module(libp2p_group_server).

-export([request_target/3, send_result/3]).

request_target(Pid, Kind, WorkerPid) ->
    gen_server:cast(Pid, {request_target, Kind, WorkerPid}).

send_result(Pid, Ref, Reason) ->
    gen_server:cast(Pid, {send_result, Ref, Reason}).
