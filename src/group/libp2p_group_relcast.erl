-module(libp2p_group_relcast).

-type opt() :: {stream_clients, [libp2p_group:stream_client_spec()]}.

-export_type([opt/0]).

-export([get_opt/3]).

-spec get_opt(libp2p_config:opts(), atom(), any()) -> any().
get_opt(Opts, Key, Default) ->
    libp2p_config:get_opt(Opts, [?MODULE, Key], Default).
