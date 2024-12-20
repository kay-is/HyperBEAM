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
-export([hd/2, tl/2, push/3, push_hashpath/2, push_request/2]).
-export([queue_request/2, pop_request/2]).
-export([verify_hashpath/3]).
-export([term_to_path/1, term_to_path/2, from_message/2]).
-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

%% @doc Extract the first key from a `Message2''s `Path' field.
%% Note: This function uses the `dev_message:get/3' function, rather than 
%% a generic call as the path should always be an explicit key in the message.
hd(Msg2, Opts) ->
    %?event({key_from_path, Msg2, Opts}),
    case pop_request(Msg2, Opts) of
        undefined -> undefined;
        {Head, _} ->
            % `term_to_path` returns the full path, so we need to take the
            % `hd` of our `Head`.
            erlang:hd(term_to_path(Head, Opts))
    end.

%% @doc Return the message without its first path element. Note that this
%% is the only transformation in Converge that does _not_ make a log of its
%% transformation. Subsequently, the message's IDs will not be verifiable 
%% after executing this transformation.
%% This may or may not be the mainnet behavior we want.
tl(Msg2, Opts) when is_map(Msg2) ->
    case pop_request(Msg2, Opts) of
        undefined -> undefined;
        {_, Rest} ->
            ?no_prod("We need to show the state transformation of the path"
                " in the message somehow."),
            Rest
    end;
tl(Path, Opts) when is_list(Path) ->
    case tl(#{ path => Path }, Opts) of
        [] -> undefined;
        undefined -> undefined;
        #{ path := Rest } -> Rest
    end.

%% @doc Add a path element to a message, according to the type given.
push(hashpath, Msg3, Msg2) ->
    push_hashpath(Msg3, Msg2);
push(request, Msg3, Msg2) ->
    push_request(Msg3, Msg2).

%%% @doc Add an ID of a Msg2 to the HashPath of another message.
push_hashpath(Msg, Msg2) when is_map(Msg2) ->
    {ok, Msg2ID} = dev_message:unsigned_id(Msg2),
    push_hashpath(Msg, Msg2ID);
push_hashpath(Msg, Msg2ID) ->
    ?no_prod("We should use the signed ID if the message is being"
        " invoked with it."),
    MsgHashpath = from_message(hashpath, Msg),
    HashpathFun = hashpath_function(Msg),
    NewHashpath = HashpathFun(hb_util:native_id(MsgHashpath), hb_util:native_id(Msg2ID)),
    TransformedMsg = Msg#{ hashpath => hb_util:human_id(NewHashpath) },
    % ?event({created_new_hashpath,
    % 	{msg1, hb_util:human_id(MsgHashpath)},
    % 	{msg2id, hb_util:human_id(Msg2ID)},
    % 	{new_hashpath, hb_util:human_id(NewHashpath)}
    % }),
    TransformedMsg.

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
    maps:put(path, term_to_path(Path) ++ from_message(request, Msg), Msg).

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
    maps:put(path, from_message(request, Msg) ++ term_to_path(Path), Msg).
	
%%% @doc Verify the HashPath of a message, given a list of messages that
%%% represent its history. Only takes the last message's HashPath-Alg into
%%% account, so shouldn't be used in production yet.
verify_hashpath(InitialMsg, CurrentMsg, MsgList) when is_map(InitialMsg) ->
    {ok, InitialMsgID} = dev_message:unsigned_id(InitialMsg),
    verify_hashpath(InitialMsgID, CurrentMsg, MsgList);
verify_hashpath(InitialMsgID, CurrentMsg, MsgList) ->
    ?no_prod("Must trace if the Hashpath-Alg has changed between messages."),
    HashpathFun = hashpath_function(CurrentMsg),
    CalculatedHashpath =
        lists:foldl(
            fun(MsgApplied, Acc) ->
                MsgID =
                    case is_map(MsgApplied) of
                        true ->
                            {ok, ID} = dev_message:unsigned_id(MsgApplied),
                            ID;
                        false -> MsgApplied
                    end,
                HashpathFun(hb_util:native_id(Acc), hb_util:native_id(MsgID))
            end,
            InitialMsgID,
            MsgList
        ),
    CurrentHashpath = from_message(hashpath, CurrentMsg),
    hb_util:human_id(CalculatedHashpath) == hb_util:human_id(CurrentHashpath).

%% @doc Extract the request path or hashpath from a message. We do not use
%% Converge for this resolution because this function is called from inside Converge 
%% itself. This imparts a requirement: the message's device must store a 
%% viable hashpath and path in its Erlang map at all times, unless the message
%% is directly from a user (in which case paths and hashpaths will not have 
%% been assigned yet).
from_message(hashpath, #{ hashpath := HashPath }) ->
    HashPath;
from_message(hashpath, Msg) ->
    ?no_prod("We should use the signed ID if the message is being"
        " invoked with it."),
    {ok, Path} = dev_message:unsigned_id(Msg),
    hd(term_to_path(Path));
from_message(request, #{ path := [] }) -> undefined;
from_message(request, #{ path := Path }) when is_list(Path) ->
    term_to_path(Path);
from_message(request, #{ path := Other }) ->
    term_to_path(Other);
from_message(request, #{ <<"path">> := Path }) -> term_to_path(Path);
from_message(request, #{ <<"Path">> := Path }) -> term_to_path(Path);
from_message(request, _) ->
    undefined.

%% @doc Return the appropriate path to refer to the for the computation of
%% Msg1(Msg2) in the form `/ID1/ID2'.
compute_path(Msg1, Msg2, _Opts) ->
    ID1 = dev_message:id(Msg1),
    ID2 = dev_message:id(Msg2),
    << "/", ID1/binary, "/", ID2/binary >>.

%% @doc Return the shortest possible reference for a given computation. If the
%% Msg2 only contains a `path' key and hashpath elements, then we can return
%% just the path.
short_compute_path(Msg1, Msg2 = #{ path := Path }, Opts) ->
    case map_size(maps:without(?CONVERGE_KEYS, Msg2)) of
        0 -> Path;
        _ -> compute_path(Msg1, Msg2, Opts)
    end.

%% @doc Convert a term into an executable path. Supports binaries, lists, and
%% atoms. Notably, it does not support strings as lists of characters.
term_to_path(Path) -> term_to_path(Path, #{ error_strategy => throw }).
term_to_path(Binary, Opts) when is_binary(Binary) ->
    case binary:match(Binary, <<"/">>) of
        nomatch -> [Binary];
        _ ->
            term_to_path(
                lists:filter(
                    fun(Part) -> byte_size(Part) > 0 end,
                    binary:split(Binary, <<"/">>, [global])
                ),
                Opts
            )
    end;
term_to_path([], _Opts) -> undefined;
term_to_path(List, Opts) when is_list(List) ->
    lists:map(
        fun(Part) ->
            hb_converge:to_key(Part, Opts)
        end,
        List
    );
term_to_path(Atom, _Opts) when is_atom(Atom) -> [Atom];
term_to_path(Integer, _Opts) when is_integer(Integer) ->
    [integer_to_binary(Integer)].

%%% TESTS

push_hashpath_test() ->
    Msg1 = #{ <<"empty">> => <<"message">> },
    Msg2 = #{ <<"exciting">> => <<"message2">> },
    Msg3 = push_hashpath(Msg1, Msg2),
    ?assert(is_binary(maps:get(hashpath, Msg3))).

push_multiple_hashpaths_test() ->
    Msg1 = #{ <<"empty">> => <<"message">> },
    Msg2 = #{ <<"exciting">> => <<"message2">> },
    Msg3 = push_hashpath(Msg1, Msg2),
    Msg4 = #{ <<"exciting">> => <<"message4">> },
    Msg5 = push_hashpath(Msg3, Msg4),
    ?assert(is_binary(maps:get(hashpath, Msg5))).

verify_hashpath_test() ->
    Msg1 = #{ <<"empty">> => <<"message">> },
    MsgB1 = #{ <<"exciting1">> => <<"message1">> },
    MsgB2 = #{ <<"exciting2">> => <<"message2">> },
    MsgB3 = #{ <<"exciting3">> => <<"message3">> },
    MsgR1 = push_hashpath(Msg1, MsgB1),
    MsgR2 = push_hashpath(MsgR1, MsgB2),
    MsgR3 = push_hashpath(MsgR2, MsgB3),
    ?assert(verify_hashpath(Msg1, MsgR3, [MsgB1, MsgB2, MsgB3])).

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
