-module(libp2p_stream_peer).

-behavior(libp2p_framed_stream).

-export([client/2, server/4, init/3, handle_data/3, handle_info/3]).

-record(state, {
          peerbook :: pid()
         }).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

init(client, _Connection, [TID, PeerList]) ->
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:join_notify(PeerBook, self()),
    case PeerList of
        [] ->
            {ok, #state{peerbook=PeerBook}};
        L ->
            {ok, #state{peerbook=PeerBook}, libp2p_peer:encode_list(L)}
    end;
init(server, _Connection, [_Path, TID]) ->
    PeerBook = libp2p_swarm:peerbook(TID),
    libp2p_peerbook:join_notify(PeerBook, self()),
    PeerList = libp2p_peerbook:values(PeerBook),
    case PeerList of
        [] ->
            {ok, #state{peerbook=PeerBook}};
        L ->
            {ok, #state{peerbook=PeerBook}, libp2p_peer:encode_list(L)}
    end.

handle_data(_, Data, State=#state{peerbook=PeerBook}) ->
    DecodedList = libp2p_peer:decode_list(Data),
    try
        libp2p_peerbook:put(PeerBook, DecodedList),
        {noreply, State}
    catch
        _:_ -> {stop, normal, State}
    end.

handle_info(_, {new_peers, NewPeers}, State=#state{}) ->
    EncodedList = libp2p_peer:encode_list(NewPeers),
    {noreply, State, EncodedList}.
