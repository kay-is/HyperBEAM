%%% @doc This module provides utilities for manipulating the paths of a
%%% message: Its request path (referred to in messages as just the `Path'), and
%%% its HashPath.
%%% 
%%% A HashPath is a rolling Merkle list of the messages that have been applied 
%%% in order to generate a given message. Because applied messages can
%%% themselves be the result of message applications with the Converge Protocol,
%%% the HashPath can be thought of as the tree of messages that represent the
%%% history of a given message. The initial message on a HashPath is referred to
%%% by its ID and serves as its user-generated 'root'.
%%% 
%%% Specifically, the HashPath can be generated by hashing the previous HashPath
%%% and the current message. This means that each message in the HashPath is
%%% dependent on all previous messages.
%%% ```
%%%     Msg1.HashPath = Msg1.ID
%%%     Msg3.HashPath = Msg1.Hash(Msg1.HashPath, Msg2.ID)
%%%     Msg3.{...} = Converge.apply(Msg1, Msg2)
%%%     ...'''
%%% 
%%% A message's ID itself includes its HashPath, leading to the mixing of
%%% a Msg2's merkle list into the resulting Msg3's HashPath. This allows a single
%%% message to represent a history _tree_ of all of the messages that were
%%% applied to generate it -- rather than just a linear history.
%%% 
%%% A message may also specify its own algorithm for generating its HashPath,
%%% which allows for custom logic to be used for representing the history of a
%%% message. When Msg2's are applied to a Msg1, the resulting Msg3's HashPath
%%% will be generated according to Msg1's algorithm choice.
-module(hb_path).
-export([hd/2, tl/2, hashpath/2, hashpath/3, push_request/2]).
-export([queue_request/2, pop_request/2]).
-export([verify_hashpath/2]).
-export([term_to_path_parts/1, term_to_path_parts/2, from_message/2]).
-export([matches/2, to_binary/1]).
-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

%% @doc Extract the first key from a `Message2''s `Path' field.
%% Note: This function uses the `dev_message:get/2' function, rather than 
%% a generic call as the path should always be an explicit key in the message.
hd(Msg2, Opts) ->
    %?event({key_from_path, Msg2, Opts}),
    case pop_request(Msg2, Opts) of
        undefined -> undefined;
        {Head, _} ->
            % `term_to_path` returns the full path, so we need to take the
            % `hd` of our `Head`.
            erlang:hd(term_to_path_parts(Head, Opts))
    end.

%% @doc Return the message without its first path element. Note that this
%% is the only transformation in Converge that does _not_ make a log of its
%% transformation. Subsequently, the message's IDs will not be verifiable 
%% after executing this transformation.
%% This may or may not be the mainnet behavior we want.
tl(Msg2, Opts) when is_map(Msg2) ->
    case pop_request(Msg2, Opts) of
        undefined -> undefined;
        {_, Rest} -> Rest
    end;
tl(Path, Opts) when is_list(Path) ->
    case tl(#{ path => Path }, Opts) of
        [] -> undefined;
        undefined -> undefined;
        #{ path := Rest } -> Rest
    end.

%%% @doc Add an ID of a Msg2 to the HashPath of another message.
hashpath(Bin, _Opts) when is_binary(Bin) ->
    % Default hashpath for a binary message is its SHA2-256 hash.
    hb_util:human_id(hb_crypto:sha256(Bin));
hashpath(Msg1, Opts) when is_map(Msg1) ->
    case dev_message:get(hashpath, Msg1) of
        {ok, Hashpath} -> Hashpath;
        _ ->
            try hb_util:ok(dev_message:id(Msg1))
            catch
                _A:_B:_ST -> throw({badarg, {unsupported_type, Msg1}})
            end
    end.
hashpath(Msg1, Msg2, Opts) when is_map(Msg2) ->
    {ok, Msg2WithoutMeta} = dev_message:remove(Msg2, #{ items => ?CONVERGE_KEYS }),
    case {map_size(Msg2WithoutMeta), hd(Msg2, Opts)} of
        {0, Key} when Key =/= undefined ->
            hashpath(Msg1, to_binary(Key), Opts);
        _ ->
            {ok, Msg2ID} = dev_message:id(Msg2),
            hashpath(Msg1, Msg2ID, Opts)
    end;
hashpath(Msg1, Msg2ID, Opts) when is_binary(Msg2ID) ->
    Msg1Hashpath = hashpath(Msg1, Opts),
    case term_to_path_parts(Msg1Hashpath) of
        [_] -> 
            << Msg1Hashpath/binary, "/", Msg2ID/binary >>;
        [Prev1, Prev2] ->
            HashpathFun = hashpath_function(Msg1),
            NativeNewBase =
                HashpathFun(hb_util:native_id(Prev1), hb_util:native_id(Prev2)),
            HumanNewBase = hb_util:human_id(NativeNewBase),
            << HumanNewBase/binary, "/", Msg2ID/binary >>
    end;
hashpath(Msg1, Msg2, Opts) ->
    throw({hashpath_not_viable, Msg2}).

%%% @doc Get the hashpath function for a message from its HashPath-Alg.
%%% If no hashpath algorithm is specified, the protocol defaults to
%%% `sha-256-chain'.
hashpath_function(Msg) ->
    case dev_message:get(<<"Hashpath-Alg">>, Msg) of
        {ok, <<"sha-256-chain">>} ->
            fun hb_crypto:sha256_chain/2;
        {ok, <<"accumulate-256">>} ->
            fun hb_crypto:accumulate/2;
        {error, not_found} ->
            fun hb_crypto:sha256_chain/2
    end.

%%% @doc Add a message to the head (next to execute) of a request path.
push_request(Msg, Path) ->
    maps:put(path, term_to_path_parts(Path) ++ from_message(request, Msg), Msg).

%%% @doc Pop the next element from a request path or path list.
pop_request(undefined, _Opts) -> undefined;
pop_request(Msg, Opts) when is_map(Msg) ->
    %?event({popping_request, {msg, Msg}, {opts, Opts}}),
    case pop_request(from_message(request, Msg), Opts) of
        undefined -> undefined;
        {undefined, _} -> undefined;
        {Head, []} -> {Head, undefined};
        {Head, Rest} ->
            ?event({popped_request, Head, Rest}),
            {Head, maps:put(path, Rest, Msg)}
    end;
pop_request([], _Opts) -> undefined;
pop_request([Head|Rest], _Opts) ->
    {Head, Rest}.

%%% @doc Queue a message at the back of a request path. `path' is the only
%%% key that we cannot use dev_message's `set/3' function for (as it expects
%%% the compute path to be there), so we use `maps:put/3' instead.
queue_request(Msg, Path) ->
    maps:put(path, from_message(request, Msg) ++ term_to_path_parts(Path), Msg).
	
%%% @doc Verify the HashPath of a message, given a list of messages that
%%% represent its history.
verify_hashpath([Msg1, Msg2, Msg3|Rest], Opts) ->
    CorrectHashpath = hashpath(Msg1, Msg2, Opts),
    FromMsg3 = from_message(hashpath, Msg3),
    CorrectHashpath == FromMsg3 andalso
        case Rest of
            [] -> true;
            _ -> verify_hashpath([Msg2, Msg3|Rest], Opts)
        end.

%% @doc Extract the request path or hashpath from a message. We do not use
%% Converge for this resolution because this function is called from inside Converge 
%% itself. This imparts a requirement: the message's device must store a 
%% viable hashpath and path in its Erlang map at all times, unless the message
%% is directly from a user (in which case paths and hashpaths will not have 
%% been assigned yet).
from_message(hashpath, Msg) -> hashpath(Msg, #{});
from_message(request, #{ path := [] }) -> undefined;
from_message(request, #{ path := Path }) when is_list(Path) ->
    term_to_path_parts(Path);
from_message(request, #{ path := Other }) ->
    term_to_path_parts(Other);
from_message(request, #{ <<"path">> := Path }) -> term_to_path_parts(Path);
from_message(request, #{ <<"Path">> := Path }) -> term_to_path_parts(Path);
from_message(request, _) ->
    undefined.

%% @doc Convert a term into an executable path. Supports binaries, lists, and
%% atoms. Notably, it does not support strings as lists of characters.
term_to_path_parts(Path) -> term_to_path_parts(Path, #{ error_strategy => throw }).
term_to_path_parts(Binary, Opts) when is_binary(Binary) ->
    case binary:match(Binary, <<"/">>) of
        nomatch -> [Binary];
        _ ->
            term_to_path_parts(
                lists:filter(
                    fun(Part) -> byte_size(Part) > 0 end,
                    binary:split(Binary, <<"/">>, [global])
                ),
                Opts
            )
    end;
term_to_path_parts([], _Opts) -> undefined;
term_to_path_parts(Path = [ASCII | _], _Opts) when is_integer(ASCII) ->
    [list_to_binary(Path)];
term_to_path_parts(List, Opts) when is_list(List) ->
    lists:flatten(lists:map(
        fun(Part) ->
            term_to_path_parts(Part, Opts)
        end,
        List
    ));
term_to_path_parts(Atom, _Opts) when is_atom(Atom) -> [Atom];
term_to_path_parts(Integer, _Opts) when is_integer(Integer) ->
    [integer_to_binary(Integer)].

%% @doc Convert a path of any form to a binary.
to_binary(Path) ->
    Parts = binary:split(do_to_binary(Path), <<"/">>, [global, trim_all]),
    iolist_to_binary(lists:join(<<"/">>, Parts)).

do_to_binary(String = [ASCII|_]) when is_integer(ASCII) ->
    to_binary(list_to_binary(String));
do_to_binary(Path) when is_list(Path) ->
    iolist_to_binary(
        lists:join(
            "/",
            lists:filtermap(
                fun(Part) ->
                    case do_to_binary(Part) of
                        <<>> -> false;
                        BinPart -> {true, BinPart}
                    end
                end,
                Path
            )
        )
    );
do_to_binary(Path) when is_binary(Path) ->
    Path;
do_to_binary(Other) ->
    hb_converge:key_to_binary(Other).

%% @doc Check if two keys match.
matches(Key1, Key2) ->
    hb_util:to_lower(hb_converge:key_to_binary(Key1)) ==
        hb_util:to_lower(hb_converge:key_to_binary(Key2)).

%%% TESTS

hashpath_test() ->
    Msg1 = #{ <<"empty">> => <<"message">> },
    Msg2 = #{ <<"exciting">> => <<"message2">> },
    Hashpath = hashpath(Msg1, Msg2, #{}),
    ?assert(is_binary(Hashpath) andalso byte_size(Hashpath) == 87).

hashpath_direct_msg2_test() ->
    Msg1 = #{ <<"Base">> => <<"Message">> },
    Msg2 = #{ path => <<"Base">> },
    Hashpath = hashpath(Msg1, Msg2, #{}),
    [_, KeyName] = term_to_path_parts(Hashpath),
    ?assert(matches(KeyName, <<"Base">>)).

multiple_hashpaths_test() ->
    Msg1 = #{ <<"empty">> => <<"message">> },
    Msg2 = #{ <<"exciting">> => <<"message2">> },
    Msg3 = #{ hashpath => hashpath(Msg1, Msg2, #{}) },
    Msg4 = #{ <<"exciting">> => <<"message4">> },
    Msg5 = hashpath(Msg3, Msg4, #{}),
    ?assert(is_binary(Msg5)).

verify_hashpath_test() ->
    Msg1 = #{ <<"TEST">> => <<"INITIAL">> },
    Msg2 = #{ <<"FirstApplied">> => <<"Msg2">> },
    Msg3 = #{ hashpath => hashpath(Msg1, Msg2, #{}) },
    Msg4 = #{ hashpath => hashpath(Msg2, Msg3, #{}) },
    Msg3Fake = #{ hashpath => hashpath(Msg4, Msg2, #{}) },
    ?assert(verify_hashpath([Msg1, Msg2, Msg3, Msg4], #{})),
    ?assertNot(verify_hashpath([Msg1, Msg2, Msg3Fake, Msg4], #{})).

validate_path_transitions(X, Opts) ->
    {Head, X2} = pop_request(X, Opts),
    ?assertEqual(a, Head),
    {H2, X3} = pop_request(X2, Opts),
    ?assertEqual(b, H2),
    {H3, X4} = pop_request(X3, Opts),
    ?assertEqual(c, H3),
    ?assertEqual(undefined, pop_request(X4, Opts)).

pop_from_message_test() ->
    validate_path_transitions(#{ path => [a, b, c] }, #{}).

pop_from_path_list_test() ->
    validate_path_transitions([a, b, c], #{}).

hd_test() ->
    ?assertEqual(a, hd(#{ path => [a, b, c] }, #{})),
    ?assertEqual(undefined, hd(#{ path => undefined }, #{})).

tl_test() ->
    ?assertMatch([b, c], maps:get(path, tl(#{ path => [a, b, c] }, #{}))),
    ?assertEqual(undefined, tl(#{ path => [] }, #{})),
    ?assertEqual(undefined, tl(#{ path => a }, #{})),
    ?assertEqual(undefined, tl(#{ path => undefined }, #{})),

    ?assertEqual([b, c], tl([a, b, c], #{ })),
    ?assertEqual(undefined, tl([c], #{ })).

to_binary_test() ->
    ?assertEqual(<<"a/b/c">>, to_binary([a, b, c])),
    ?assertEqual(<<"a/b/c">>, to_binary(<<"a/b/c">>)),
    ?assertEqual(<<"a/b/c">>, to_binary([<<"a">>, b, [<<"c">>]])),
    ?assertEqual(<<"a/b/c">>, to_binary(["a", b, <<"c">>])),
    ?assertEqual(<<"a/b/b/c">>, to_binary([<<"a">>, [<<"b">>, <<"//b">>], <<"c">>])).

term_to_path_parts_test() ->
    ?assert(matches([a, b, c], term_to_path_parts(<<"a/b/c">>))),
    ?assert(matches([a, b, c], term_to_path_parts([<<"a">>, <<"b">>, <<"c">>]))),
    ?assert(matches([a, b, c], term_to_path_parts(["a", b, <<"c">>]))),
    ?assert(matches([a, b, b, c], term_to_path_parts([[<<"/a">>, [<<"b">>, <<"//b">>], <<"c">>]]))).
