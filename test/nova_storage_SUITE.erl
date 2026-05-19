-module(nova_storage_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
        put_then_get_roundtrip,
        head_returns_meta_only,
        delete_removes_object,
        copy_creates_destination,
        exists_reflects_state,
        get_returns_not_found_for_missing,
        list_returns_objects_in_prefix,
        max_size_rejects_oversize,
        content_type_required_on_put,
        sign_url_returns_not_supported_for_local
    ].

init_per_suite(Config) ->
    Root = mk_root(Config),
    _ = application:load(nova_storage),
    application:set_env(nova_storage, stores, #{
        suite => #{adapter => nova_storage_local, root => Root, max_size => 1_000_000}
    }),
    {ok, _} = application:ensure_all_started(nova_storage),
    [{root, Root} | Config].

end_per_suite(_Config) ->
    ok = application:stop(nova_storage),
    ok.

init_per_testcase(_, Config) ->
    Root = ?config(root, Config),
    cleanup_root(Root),
    Config.

end_per_testcase(_, _) ->
    ok.

put_then_get_roundtrip(_Config) ->
    {ok, Meta} = nova_storage:put(suite, <<"a.txt">>, <<"hello">>, #{
        content_type => <<"text/plain">>
    }),
    <<"a.txt">> = maps:get(key, Meta),
    5 = maps:get(size, Meta),
    {ok, Body, Meta2} = nova_storage:get(suite, <<"a.txt">>),
    <<"hello">> = iolist_to_binary(Body),
    <<"a.txt">> = maps:get(key, Meta2).

head_returns_meta_only(_Config) ->
    {ok, _} = nova_storage:put(suite, <<"b.txt">>, <<"x">>, #{content_type => <<"text/plain">>}),
    {ok, Meta} = nova_storage:head(suite, <<"b.txt">>),
    1 = maps:get(size, Meta).

delete_removes_object(_Config) ->
    {ok, _} = nova_storage:put(suite, <<"d.txt">>, <<"x">>, #{content_type => <<"text/plain">>}),
    ok = nova_storage:delete(suite, <<"d.txt">>),
    not_found = nova_storage:get(suite, <<"d.txt">>).

copy_creates_destination(_Config) ->
    {ok, _} = nova_storage:put(suite, <<"src">>, <<"abc">>, #{content_type => <<"text/plain">>}),
    {ok, DestMeta} = nova_storage:copy(suite, <<"src">>, <<"dst">>),
    <<"dst">> = maps:get(key, DestMeta),
    {ok, Body, _} = nova_storage:get(suite, <<"dst">>),
    <<"abc">> = iolist_to_binary(Body).

exists_reflects_state(_Config) ->
    false = nova_storage:exists(suite, <<"missing">>),
    {ok, _} = nova_storage:put(suite, <<"e.txt">>, <<"x">>, #{content_type => <<"text/plain">>}),
    true = nova_storage:exists(suite, <<"e.txt">>).

get_returns_not_found_for_missing(_Config) ->
    not_found = nova_storage:get(suite, <<"nope">>).

list_returns_objects_in_prefix(_Config) ->
    {ok, _} = nova_storage:put(suite, <<"users/a">>, <<"1">>, #{content_type => <<"text/plain">>}),
    {ok, _} = nova_storage:put(suite, <<"users/b">>, <<"2">>, #{content_type => <<"text/plain">>}),
    {ok, _} = nova_storage:put(suite, <<"other/c">>, <<"3">>, #{content_type => <<"text/plain">>}),
    {ok, Metas, _} = nova_storage:list(suite, <<"users/">>),
    Keys = lists:sort([maps:get(key, M) || M <- Metas]),
    [<<"users/a">>, <<"users/b">>] = Keys.

max_size_rejects_oversize(_Config) ->
    Big = binary:copy(<<"x">>, 1_500_000),
    {error, {object_too_large, _, _}} = nova_storage:put(
        suite, <<"big">>, Big, #{content_type => <<"text/plain">>}
    ).

content_type_required_on_put(_Config) ->
    try
        nova_storage:put(suite, <<"k">>, <<"v">>, #{}),
        ct:fail(should_have_errored)
    catch
        error:content_type_required -> ok
    end.

sign_url_returns_not_supported_for_local(_Config) ->
    {error, not_supported} = nova_storage:sign_url(suite, <<"k">>, get).

%% Helpers

mk_root(Config) ->
    PrivDir = ?config(priv_dir, Config),
    R = filename:join(PrivDir, "store"),
    ok = filelib:ensure_path(R),
    R.

cleanup_root(Root) ->
    case file:list_dir(Root) of
        {ok, Files} ->
            [_ = del_recursive(filename:join(Root, F)) || F <- Files],
            ok;
        _ ->
            ok
    end.

del_recursive(Path) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, Files} = file:list_dir(Path),
            [del_recursive(filename:join(Path, F)) || F <- Files],
            file:del_dir(Path);
        false ->
            file:delete(Path)
    end.
