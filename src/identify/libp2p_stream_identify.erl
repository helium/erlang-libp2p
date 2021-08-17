-module(libp2p_stream_identify).

-include("pb/libp2p_identify_pb.hrl").

-behavior(libp2p_framed_stream).

-export([dial_spawn/3]).
-export([client/2, server/4, init/3, handle_data/3, handle_info/3]).

-record(state,
       { tid :: ets:tab(),
         session :: pid(),
         handler:: pid(),
         timeout :: reference()
       }).

-define(PATH, "identify/1.0.0").
-define(TIMEOUT, 5000).

-spec dial_spawn(Session::pid(), ets:tab(), Handler::pid()) -> {pid(), reference()}.
dial_spawn(Session, TID, Handler) ->
    spawn_monitor(
      fun() ->
              Challenge = crypto:strong_rand_bytes(20),
              Path = lists:flatten([?PATH, "/", base58:binary_to_base58(Challenge)]),
              libp2p_session:dial_framed_stream(Path, Session, ?MODULE, [TID, Handler])
      end).

client(Connection, Args=[_TID, _Handler]) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, TID, []) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path, TID]).

init(client, Connection, [_TID, Handler]) ->
    case libp2p_connection:session(Connection) of
        {ok, Session} ->
            Timer = erlang:send_after(?TIMEOUT, self(), identify_timeout),
            {ok, #state{handler=Handler, session=Session, timeout=Timer}};
        {error, Error} ->
            lager:debug("Identify failed to get session: ~p", [Error]),
            {stop, normal}
    end;
init(server, Connection, [Path, TID]) ->
    "/" ++ Str = Path,
    Challenge = base58:base58_to_binary(Str),
    {ok, _, SigFun, _} = libp2p_swarm:keys(TID),
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    {ok, Peer} = libp2p_peerbook:get(libp2p_swarm:peerbook(TID), libp2p_swarm:pubkey_bin(TID)),
    Identify = libp2p_identify:from_map(#{peer => Peer,
                                          observed_addr => RemoteAddr,
                                          nonce => Challenge},
                                        SigFun),
    {stop, normal, libp2p_identify:encode(Identify)}.


handle_data(client, Data, State=#state{}) ->
    erlang:cancel_timer(State#state.timeout),
    State#state.handler ! {handle_identify, State#state.session, libp2p_identify:decode(Data)},
    {stop, normal, State}.


handle_info(client, identify_timeout, State=#state{}) ->
    State#state.handler ! {handle_identify, State#state.session, {error, timeout}},
    lager:notice("Identify timed out"),
    {stop, normal, State}.
