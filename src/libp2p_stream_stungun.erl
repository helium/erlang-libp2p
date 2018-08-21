-module(libp2p_stream_stungun).

-behavior(libp2p_framed_stream).

-type txn_id() :: non_neg_integer().
-export_type([txn_id/0]).

%% API
-export([mk_stun_txn/0, dial/5]).
%% libp2p_framed_stream
-export([client/2, server/4, init/3, handle_data/3]).

-define(OK, <<0:8/integer-unsigned>>).
-define(PORT_RESTRICTED_NAT, <<1:8/integer-unsigned>>).
-define(SYMMETRIC_NAT, <<2:8/integer-unsigned>>).

-record(client_state, {
          txn_id :: binary(),
          handler :: pid()
         }).

%%
%% API
%%

-spec mk_stun_txn() -> {string(), txn_id()}.
mk_stun_txn() ->
    <<TxnID:96/integer-unsigned-little>> = crypto:strong_rand_bytes(12),
    PeerPath = lists:flatten(io_lib:format("stungun/1.0.0/dial/~b", [TxnID])),
    {PeerPath, TxnID}.

-spec dial(ets:tab(), string(), string(), txn_id(), pid()) -> {ok, pid()} | {error, term()}.
dial(TID, PeerAddr, PeerPath, TxnID, Handler) ->
    libp2p_swarm:dial_framed_stream(TID, PeerAddr, PeerPath, ?MODULE, [TxnID, Handler]).

%%
%% libp2p_framed_stream
%%

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(client, _Connection, [TxnID, Handler]) ->
    {ok, #client_state{txn_id=TxnID, handler=Handler}};
init(server, Connection, ["/dial/"++TxnID, _, TID]) ->
    {_, ObservedAddr} = libp2p_connection:addr_info(Connection),
    %% first, try with the unique dial option, so we can check if the peer has Full Cone or Restricted Cone NAT
    ReplyPath = lists:flatten(io_lib:format("stungun/1.0.0/reply/~b", [list_to_integer(TxnID)])),
    case libp2p_swarm:dial(TID, ObservedAddr, ReplyPath,
                           [{unique_session, true}, {unique_port, true}], 5000) of
        {ok, C} ->
            libp2p_connection:close(C),
            %% ok they have full-cone or restricted cone NAT
            %% without trying from an unrelated IP we can't distinguish
            {stop, normal, ?OK};
        {error, _} ->
            case libp2p_swarm:dial(TID, ObservedAddr, ReplyPath, [{unique_session, true}], 5000) of
                {ok, C2} ->
                    %% ok they have port restricted cone NAT
                    libp2p_connection:close(C2),
                    {stop, normal, ?PORT_RESTRICTED_NAT};
                {error, _} ->
                    %% reply here to tell the peer we can't dial back at all
                    %% and they're behind symmetric NAT
                    {stop, normal, ?SYMMETRIC_NAT}
            end
    end;
init(server, Connection, ["/reply/"++TxnID, Handler, _TID]) ->
    {LocalAddr, _} = libp2p_connection:addr_info(Connection),
    Handler ! {stungun_reply, list_to_integer(TxnID), LocalAddr},
    {stop, normal}.

handle_data(client, Code, State=#client_state{txn_id=TxnID, handler=Handler}) ->
    {NatType, _Info} = to_nat_type(Code),
    Handler ! {stungun_nat, TxnID, NatType},
    {stop, normal, State};

handle_data(server, _,  _) ->
    {stop, normal, undefined}.


%%
%% Internal
%%

to_nat_type(?OK) ->
    {unknown, "Full cone or restricted cone nat detected"};
to_nat_type(?PORT_RESTRICTED_NAT) ->
    {restricted, "Port restricted cone nat detected"};
to_nat_type(?SYMMETRIC_NAT) ->
    {symmetric, "Symmetric nat detected, RIP"}.
