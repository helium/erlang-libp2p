-module(libp2p_lager_metadata).

-export([types/0, update/1, from_strings/1]).

-type md_type() :: pid
                 | module
                 | function
                 | line
                 | target
                 | path
                 | string
                 | index
                 | group_id
                 | session_local
                 | session_remote.
-export_type([md_type/0]).

-spec types() -> #{md_type() => cuttlefish_datatypes:datatype()}.
types() ->
    #{
      pid => string,
      module => atom,
      function => atom,
      line => integer,
      target => string,
      path => string,
      index => integer,
      group_id => string,
      session_local => string,
      session_remote => string
     }.

-spec update([{md_type(), any()}]) -> ok.
update(MD) ->
    lager:md(lists:foldl(fun({K, V}, Acc) ->
                                 lists:keystore(K, 1, Acc, {K, V})
                         end, lager:md(), MD)).

-spec from_strings([{string(), string()}]) -> [{atom(), any()}].
from_strings(StrMD) ->
    from_strings(StrMD, types()).

-spec from_strings([{string(), string()}], #{md_type() => atom()}) -> [{md_type(), any()}].
from_strings(StrMD, Types) ->
    lists:foldl(fun({StrKey, StrVal}, Acc) ->
                        case (catch list_to_existing_atom(StrKey)) of
                            {'EXIT', _} -> Acc;
                            Key ->
                                case maps:get(Key, Types, undefined) of
                                    undefined -> Acc;
                                    Type ->
                                        case cuttlefish_datatypes:from_string(StrVal, Type) of
                                            {error, _} -> Acc;
                                            Value -> [{Key, Value} | Acc]
                                        end
                                end
                        end;
                   (_, Acc) ->
                        Acc
                end, [], StrMD).

%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

from_strings_test() ->
    ?assertEqual([{pid, "<pid>"}], from_strings([{"pid", "<pid>"}])),
    ?assertEqual([{module, libp2p_lager_metadata}], from_strings([{"module", "libp2p_lager_metadata"}])),
    ?assertEqual([{function, from_strings_test}], from_strings([{"function", "from_strings_test"}])),
    ?assertEqual([{line, 72}], from_strings([{"line", "72"}])),

    ?assertEqual([{target, "foo"}], from_strings([{"target", "foo"}])),
    ?assertEqual([{path, "path"}], from_strings([{"path", "path"}])),
    ?assertEqual([{index, 22}], from_strings([{"index", "22"}])),
    ?assertEqual([{group_id, "group"}], from_strings([{"group_id", "group"}])),
    ?assertEqual([{session_local, "/ip4/blah"}], from_strings([{"session_local", "/ip4/blah"}])),
    ?assertEqual([{session_remote, "/ip4/blah"}], from_strings([{"session_remote", "/ip4/blah"}])),

    ?assertEqual([], from_strings([{"index", "foo"}])),

    ok.

-endif.
