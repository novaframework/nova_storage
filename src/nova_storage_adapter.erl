-module(nova_storage_adapter).
-moduledoc """
Behaviour for nova_storage adapters.

Each adapter owns its own process and holds an opaque `State` that
`nova_storage` passes back to subsequent callbacks verbatim. All time
values are in milliseconds. All sizes are in bytes.

## Streaming

`put` may receive `Body` as `iodata()` (small objects) or `{stream, ChunkFun}`
where `ChunkFun` is `fun(() -> {chunk, binary()} | eof | {error, term()})`.

`ChunkFun` is called by the adapter, **in the adapter's process,
synchronously**. Producers must not block waiting on the adapter (`gen_server`
deadlock) and must respect the configured `chunk_timeout`.

`get_stream` returns a `ChunkFun` that the caller pulls from until `eof`.

## ETag

The `etag` field in `object_meta()` is adapter-defined. For S3, it equals the
content MD5 only for single-part uploads; multipart uploads use a different
scheme. Treat `etag` as an opaque change indicator, not a content hash.
""".

-type key() :: binary().
-type body() :: iodata() | {stream, chunk_fun()}.
-type chunk_fun() :: fun(() -> {chunk, binary()} | eof | {error, term()}).
-type put_opts() :: #{
    content_type => binary(),
    user_meta => #{binary() => binary()},
    chunk_timeout => non_neg_integer()
}.
-type sign_opts() :: #{
    expires_in => non_neg_integer(),
    content_type => binary()
}.
-type list_opts() :: #{
    cursor => binary() | done,
    limit => pos_integer()
}.
-type object_meta() :: #{
    key := key(),
    size := non_neg_integer(),
    content_type => binary(),
    etag => binary(),
    last_modified => non_neg_integer(),
    user_meta => #{binary() => binary()}
}.

-export_type([key/0, body/0, chunk_fun/0, put_opts/0, sign_opts/0, list_opts/0, object_meta/0]).

-callback start_link(Name :: atom(), Opts :: map()) -> {ok, pid()} | {error, term()}.
-callback put(Key :: key(), Body :: body(), Opts :: put_opts(), State :: term()) ->
    {ok, object_meta()} | {error, term()}.
-callback get(Key :: key(), State :: term()) ->
    {ok, iodata(), object_meta()} | not_found | {error, term()}.
-callback get_stream(Key :: key(), State :: term()) ->
    {ok, chunk_fun(), object_meta()} | not_found | {error, term()}.
-callback head(Key :: key(), State :: term()) -> {ok, object_meta()} | not_found | {error, term()}.
-callback delete(Key :: key(), State :: term()) -> ok | {error, term()}.
-callback copy(Source :: key(), Dest :: key(), State :: term()) ->
    {ok, object_meta()} | {error, term()}.
-callback exists(Key :: key(), State :: term()) -> boolean() | {error, term()}.
-callback sign_url(
    Key :: key(),
    Method :: get | put,
    Opts :: sign_opts(),
    State :: term()
) -> {ok, binary()} | {error, term()}.
-callback list(Prefix :: binary(), Opts :: list_opts(), State :: term()) ->
    {ok, [object_meta()], Cursor :: binary() | done} | {error, term()}.
