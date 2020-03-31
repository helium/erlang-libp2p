-module(libp2p_peerbook_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/5,
    peerbook/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(PEERBOOK, swarm_peerbook).

%%====================================================================
%% API functions
%%====================================================================

start_link(Opts, TID, Name, PubKey, SigFun) ->
    supervisor:start_link({local, reg_name(TID)}, ?MODULE, [Opts, TID, Name, PubKey, SigFun]).

-spec peerbook(ets:tab()) -> pid().
peerbook(TID) ->
    ets:lookup_element(TID, ?PEERBOOK, 2).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
init([Opts, TID, Name, PubKey, SigFun]) ->
    IsSeedNode = application:get_env(libp2p, seed_node, false),
    DataDir = libp2p_config:swarm_dir(TID, [Name]),
    CallbackFun = fun(FunTID, Handle) -> libp2p_swarm:store_peerbook(FunTID, Handle) end,
    SuppliedPBOpts = proplists:get_value(libp2p_peerbook, Opts, []),
    PeerbookOpts0 = #{
                     sig_fun => SigFun,
                     data_dir => DataDir,
                     pubkey_bin => libp2p_crypto:pubkey_to_bin(PubKey),
                     register_callback =>  CallbackFun,
                     register_ref => TID,
                     seed_node => IsSeedNode

    },
    PeerbookOpts1 = maps:from_list(SuppliedPBOpts),  %% NOTE: values from the supplied map superceed any defined above
    PeerbookOpts = maps:merge(PeerbookOpts0, PeerbookOpts1),

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

reg_name(Name)->
    libp2p_swarm:reg_name_from_tid(Name, ?MODULE).

