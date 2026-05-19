-module(nova_storage).
-moduledoc """
Public API for the nova_storage library.

Object/file storage abstraction with pluggable adapters. Bytes-in / bytes-out;
encryption-at-rest is `nova_vault`'s job, audit is `nova_audit`'s.

## Quick start

```erlang
%% sys.config
{nova_storage, [
    {stores, #{
        avatars => #{
            adapter => nova_storage_local,
            root => "/var/data/avatars",
            max_size => 5_000_000
        },
        uploads => #{
            adapter => nova_storage_s3,
            bucket => <<"my-uploads">>,
            region => <<"eu-west-1">>,
            access_key => {env, "S3_ACCESS_KEY"},
            secret_key => {env, "S3_SECRET_KEY"}
        }
    }}
]}.

%% application code
{ok, Meta} = nova_storage:put(avatars, <<"alice.png">>, PngBytes, #{content_type => <<"image/png">>}),
{ok, Body, Meta} = nova_storage:get(avatars, <<"alice.png">>),
{ok, Url} = nova_storage:sign_url(uploads, <<"some/key">>, get, #{expires_in => 3600}).
```

## Stability

`nova_storage` is NOT a dependency of nova core and must never become one.
Audit logging belongs in `nova_audit`. Encryption-at-rest belongs in
`nova_vault`. Image transforms belong in a separate library.
""".

-export([
    put/4,
    get/2,
    get_stream/2,
    head/2,
    delete/2,
    copy/3,
    exists/2,
    sign_url/3,
    sign_url/4,
    list/2,
    list/3
]).

-type store_name() :: atom().

-export_type([store_name/0]).

-spec put(
    store_name(),
    nova_storage_adapter:key(),
    nova_storage_adapter:body(),
    nova_storage_adapter:put_opts()
) -> {ok, nova_storage_adapter:object_meta()} | {error, term()}.
put(StoreName, Key, Body, Opts) ->
    require_content_type(Opts),
    with_store(StoreName, fun(Adapter, State, StoreOpts) ->
        case max_size_ok(Body, StoreOpts) of
            ok ->
                telemetry_span(put, StoreName, Adapter, Key, fun() ->
                    Adapter:put(Key, Body, Opts, State)
                end);
            {error, _} = E ->
                E
        end
    end).

-spec get(store_name(), nova_storage_adapter:key()) ->
    {ok, iodata(), nova_storage_adapter:object_meta()} | not_found | {error, term()}.
get(StoreName, Key) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        telemetry_span(get, StoreName, Adapter, Key, fun() ->
            Adapter:get(Key, State)
        end)
    end).

-spec get_stream(store_name(), nova_storage_adapter:key()) ->
    {ok, nova_storage_adapter:chunk_fun(), nova_storage_adapter:object_meta()}
    | not_found
    | {error, term()}.
get_stream(StoreName, Key) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        telemetry_span(get_stream, StoreName, Adapter, Key, fun() ->
            Adapter:get_stream(Key, State)
        end)
    end).

-spec head(store_name(), nova_storage_adapter:key()) ->
    {ok, nova_storage_adapter:object_meta()} | not_found | {error, term()}.
head(StoreName, Key) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        telemetry_span(head, StoreName, Adapter, Key, fun() ->
            Adapter:head(Key, State)
        end)
    end).

-spec delete(store_name(), nova_storage_adapter:key()) -> ok | {error, term()}.
delete(StoreName, Key) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        telemetry_span(delete, StoreName, Adapter, Key, fun() ->
            Adapter:delete(Key, State)
        end)
    end).

-spec copy(store_name(), nova_storage_adapter:key(), nova_storage_adapter:key()) ->
    {ok, nova_storage_adapter:object_meta()} | {error, term()}.
copy(StoreName, Source, Dest) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        telemetry_span(copy, StoreName, Adapter, Source, fun() ->
            Adapter:copy(Source, Dest, State)
        end)
    end).

-spec exists(store_name(), nova_storage_adapter:key()) -> boolean() | {error, term()}.
exists(StoreName, Key) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        Adapter:exists(Key, State)
    end).

-spec sign_url(store_name(), nova_storage_adapter:key(), get | put) ->
    {ok, binary()} | {error, term()}.
sign_url(StoreName, Key, Method) ->
    sign_url(StoreName, Key, Method, #{}).

-spec sign_url(
    store_name(), nova_storage_adapter:key(), get | put, nova_storage_adapter:sign_opts()
) ->
    {ok, binary()} | {error, term()}.
sign_url(StoreName, Key, Method, Opts) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        Adapter:sign_url(Key, Method, Opts, State)
    end).

-spec list(store_name(), binary()) ->
    {ok, [nova_storage_adapter:object_meta()], binary() | done} | {error, term()}.
list(StoreName, Prefix) ->
    list(StoreName, Prefix, #{}).

-spec list(store_name(), binary(), nova_storage_adapter:list_opts()) ->
    {ok, [nova_storage_adapter:object_meta()], binary() | done} | {error, term()}.
list(StoreName, Prefix, Opts) ->
    with_store(StoreName, fun(Adapter, State, _StoreOpts) ->
        Adapter:list(Prefix, Opts, State)
    end).

%% Internal

with_store(StoreName, Fun) ->
    case nova_storage_registry:lookup(StoreName) of
        {ok, Adapter, State} ->
            StoreOpts = store_opts(StoreName),
            Fun(Adapter, State, StoreOpts);
        {error, _} = E ->
            E
    end.

store_opts(StoreName) ->
    case application:get_env(nova_storage, stores, #{}) of
        #{StoreName := Spec} -> Spec;
        _ -> #{}
    end.

require_content_type(#{content_type := _}) -> ok;
require_content_type(_) -> error(content_type_required).

max_size_ok(_Body, #{max_size := infinity}) ->
    ok;
max_size_ok(_Body, Opts) when not is_map_key(max_size, Opts) ->
    ok;
max_size_ok({stream, _}, _Opts) ->
    ok;
max_size_ok(Body, #{max_size := Max}) ->
    case iolist_size(Body) of
        N when N =< Max -> ok;
        N -> {error, {object_too_large, N, Max}}
    end.

telemetry_span(Op, StoreName, Adapter, Key, Fun) ->
    Start = erlang:monotonic_time(),
    StartMeta = #{store => StoreName, adapter => Adapter, key => Key},
    emit_telemetry([nova_storage, Op, start], #{system_time => erlang:system_time()}, StartMeta),
    try Fun() of
        Result ->
            Duration = erlang:monotonic_time() - Start,
            emit_telemetry(
                [nova_storage, Op, stop],
                #{duration => Duration},
                StartMeta#{result => result_tag(Result)}
            ),
            Result
    catch
        Class:Reason:Stack ->
            Duration = erlang:monotonic_time() - Start,
            emit_telemetry(
                [nova_storage, Op, exception],
                #{duration => Duration},
                StartMeta#{kind => Class, reason => Reason, stacktrace => Stack}
            ),
            erlang:raise(Class, Reason, Stack)
    end.

emit_telemetry(Event, Measurements, Meta) ->
    case code:is_loaded(telemetry) of
        {file, _} ->
            try
                M = telemetry,
                F = execute,
                apply(M, F, [Event, Measurements, Meta])
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end.

result_tag(ok) -> ok;
result_tag({ok, _}) -> ok;
result_tag({ok, _, _}) -> ok;
result_tag(not_found) -> not_found;
result_tag({error, _}) -> error;
result_tag(_) -> other.
