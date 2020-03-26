-module(libp2p_peerbook_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/4
]).

%% Supervisor callbacks
-export([init/1]).

-define(PEERBOOK, swarm_peerbook).

%% Default "this" peer heartbeat time 5 minutes (in milliseconds)
-define(DEFAULT_PEER_TIME, 5 * 60 * 1000).

%% Default timer for new peer notifications to connected peers. This
%% allows for fast arrivels to coalesce a number of new peers before a
%% new list is sent out.
-define(DEFAULT_NOTIFY_TIME, 5 * 1000).

%%====================================================================
%% API functions
%%====================================================================

start_link(TID, Name, PubKey, SigFun) ->
    supervisor:start_link({local, reg_name(TID)}, ?MODULE, [TID, Name, PubKey, SigFun]).

reg_name(Name)->
    libp2p_swarm:reg_name_from_tid(Name, ?MODULE).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([TID, Name, PubKey, SigFun]) ->
    DataDir = libp2p_config:swarm_dir(TID, [Name]),
    CallbackFun = fun(FunTID, Handle) -> libp2p_swarm:store_peerbook(FunTID, Handle) end,
    PeerbookOpts = #{
                     sig_fun => SigFun,
                     data_dir => DataDir,
                     pubkey_bin => libp2p_crypto:pubkey_to_bin(PubKey),
                     notify_time => ?DEFAULT_NOTIFY_TIME, peer_time => ?DEFAULT_PEER_TIME,
                     register_callback =>  CallbackFun,
                     register_ref => TID

    },
    ChildSpecs = [
        {?PEERBOOK,
            {libp2p_peerbook, start_link, [PeerbookOpts]},
            permanent,
            10000,
            worker,
            [libp2p_peerbook]
        }
    ],
    SupFlags = {one_for_one, 5, 10},
    {ok, {SupFlags, ChildSpecs}}.
%%====================================================================
%% Internal functions
%%====================================================================
