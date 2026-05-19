-module(nova_storage_s3).
-moduledoc """
S3-compatible adapter for `nova_storage`.

Speaks the S3 REST API with SigV4 signing via `nova_storage_sigv4`. Works
against AWS S3, Cloudflare R2, Scaleway Object Storage, Minio, and Backblaze
B2 (S3-compatible endpoint).

## Configuration

```erlang
#{
    adapter => nova_storage_s3,
    bucket => <<"my-bucket">>,
    region => <<"eu-west-1">>,
    endpoint => <<"https://s3.eu-west-1.amazonaws.com">>,  %% optional, derived for AWS
    access_key => {env, "S3_ACCESS_KEY"},
    secret_key => {env, "S3_SECRET_KEY"},
    addressing_style => virtual,  %% or path
    session_token => undefined,
    max_size => infinity
}
```

R2 / Scaleway / Minio: supply `endpoint` and prefer `addressing_style => path`
for Minio, `virtual` for R2 + AWS, either for Scaleway.

## Streaming caveats

`get_stream` reads the entire response into memory before delivering chunks
because `httpc`'s body-streaming API requires a `receiver` process, not a
pull-based stream. For objects above ~32 MB use `sign_url/3,4` and have the
client transfer directly. A `gun`-based adapter will land in v0.2.

## Sign URL

`sign_url(Key, get, Opts, State)` returns a presigned GET URL. `put` signing
is deferred to v0.2.
""".

-behaviour(gen_server).
-behaviour(nova_storage_adapter).

-export([start_link/2]).
-export([put/4, get/2, get_stream/2, head/2, delete/2, copy/3, exists/2, sign_url/4, list/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {name :: atom(), handle :: term()}).
-record(handle, {
    name :: atom(),
    bucket :: binary(),
    region :: binary(),
    endpoint :: binary(),
    addressing :: virtual | path,
    creds :: nova_storage_sigv4:credentials()
}).

start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

put(Key, Body, Opts, #handle{} = H) ->
    ContentType = maps:get(content_type, Opts, <<"application/octet-stream">>),
    UserMeta = maps:get(user_meta, Opts, #{}),
    BodyBin = body_to_binary(Body, maps:get(chunk_timeout, Opts, 30_000)),
    Headers0 = [
        {<<"content-type">>, ContentType},
        {<<"content-length">>, integer_to_binary(byte_size(BodyBin))}
    ],
    Headers1 = Headers0 ++ user_meta_headers(UserMeta),
    case do_request(<<"PUT">>, H, Key, [], Headers1, BodyBin) of
        {ok, 200, RespHeaders, _} ->
            {ok, build_meta(Key, byte_size(BodyBin), ContentType, RespHeaders, UserMeta)};
        {ok, Status, _, Body2} ->
            {error, {http_status, Status, Body2}};
        {error, _} = E ->
            E
    end.

get(Key, #handle{} = H) ->
    case do_request(<<"GET">>, H, Key, [], [], <<>>) of
        {ok, 200, RespHeaders, Body} ->
            {ok, Body,
                build_meta(Key, byte_size(Body), content_type_of(RespHeaders), RespHeaders, #{})};
        {ok, 404, _, _} ->
            not_found;
        {ok, Status, _, Body} ->
            {error, {http_status, Status, Body}};
        {error, _} = E ->
            E
    end.

get_stream(Key, #handle{} = H) ->
    case get(Key, H) of
        {ok, Body, Meta} ->
            {ok, single_chunk_fun(Body), Meta};
        Other ->
            Other
    end.

head(Key, #handle{} = H) ->
    case do_request(<<"HEAD">>, H, Key, [], [], <<>>) of
        {ok, 200, RespHeaders, _} ->
            {ok,
                build_meta(
                    Key, size_of(RespHeaders), content_type_of(RespHeaders), RespHeaders, #{}
                )};
        {ok, 404, _, _} ->
            not_found;
        {ok, Status, _, Body} ->
            {error, {http_status, Status, Body}};
        {error, _} = E ->
            E
    end.

delete(Key, #handle{} = H) ->
    case do_request(<<"DELETE">>, H, Key, [], [], <<>>) of
        {ok, S, _, _} when S =:= 204; S =:= 200 -> ok;
        {ok, Status, _, Body} -> {error, {http_status, Status, Body}};
        {error, _} = E -> E
    end.

copy(Source, Dest, #handle{bucket = Bucket} = H) ->
    CopyHeader = {<<"x-amz-copy-source">>, <<"/", Bucket/binary, "/", Source/binary>>},
    case do_request(<<"PUT">>, H, Dest, [], [CopyHeader], <<>>) of
        {ok, 200, RespHeaders, _} ->
            {ok,
                build_meta(
                    Dest, size_of(RespHeaders), content_type_of(RespHeaders), RespHeaders, #{}
                )};
        {ok, Status, _, Body} ->
            {error, {http_status, Status, Body}};
        {error, _} = E ->
            E
    end.

exists(Key, #handle{} = H) ->
    case head(Key, H) of
        {ok, _} -> true;
        not_found -> false;
        {error, _} = E -> E
    end.

sign_url(Key, get, Opts, #handle{} = H) ->
    ExpiresIn = maps:get(expires_in, Opts, 3600),
    Url = key_url(H, Key, []),
    nova_storage_sigv4:presign(
        <<"GET">>,
        Url,
        [],
        H#handle.creds,
        #{region => H#handle.region, service => <<"s3">>},
        ExpiresIn
    );
sign_url(_Key, put, _Opts, _State) ->
    {error, put_signing_in_v0_2}.

list(Prefix, Opts, #handle{} = H) ->
    Query0 = [
        {<<"list-type">>, <<"2">>},
        {<<"prefix">>, Prefix},
        {<<"max-keys">>, integer_to_binary(maps:get(limit, Opts, 1000))}
    ],
    Query =
        case maps:get(cursor, Opts, undefined) of
            undefined -> Query0;
            done -> Query0;
            C when is_binary(C) -> [{<<"continuation-token">>, C} | Query0]
        end,
    case do_request(<<"GET">>, H, <<>>, Query, [], <<>>) of
        {ok, 200, _, Body} ->
            {Metas, NextCursor} = nova_storage_s3_xml:parse_list_v2(Body),
            {ok, Metas, NextCursor};
        {ok, Status, _, Body} ->
            {error, {http_status, Status, Body}};
        {error, _} = E ->
            E
    end.

init({Name, Opts}) ->
    Bucket = required(bucket, Opts),
    Region = required(region, Opts),
    Endpoint = endpoint_from(Opts, Region),
    Addressing = maps:get(addressing_style, Opts, virtual),
    Creds = #{
        access_key => resolve_secret(maps:get(access_key, Opts)),
        secret_key => resolve_secret(maps:get(secret_key, Opts))
    },
    Creds2 =
        case maps:get(session_token, Opts, undefined) of
            undefined -> Creds;
            T -> Creds#{session_token => resolve_secret(T)}
        end,
    Handle = #handle{
        name = Name,
        bucket = Bucket,
        region = Region,
        endpoint = Endpoint,
        addressing = Addressing,
        creds = Creds2
    },
    _ = inets:start(),
    _ = ssl:start(),
    ok = nova_storage_registry:register(Name, ?MODULE, Handle),
    {ok, #state{name = Name, handle = Handle}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.

%% Internal

required(K, Opts) ->
    case maps:find(K, Opts) of
        {ok, V} -> V;
        error -> error({missing_required_option, K})
    end.

endpoint_from(Opts, Region) ->
    case maps:get(endpoint, Opts, undefined) of
        undefined -> <<"https://s3.", Region/binary, ".amazonaws.com">>;
        E when is_binary(E) -> E
    end.

resolve_secret({env, VarName}) ->
    case os:getenv(VarName) of
        false -> error({env_var_not_set, VarName});
        V -> list_to_binary(V)
    end;
resolve_secret(V) when is_binary(V) ->
    V.

key_url(#handle{endpoint = Endpoint, bucket = Bucket, addressing = virtual}, Key, Query) ->
    add_query(<<(insert_subdomain(Endpoint, Bucket))/binary, "/", Key/binary>>, Query);
key_url(#handle{endpoint = Endpoint, bucket = Bucket, addressing = path}, Key, Query) ->
    add_query(<<Endpoint/binary, "/", Bucket/binary, "/", Key/binary>>, Query).

insert_subdomain(Endpoint, Bucket) ->
    case binary:split(Endpoint, <<"://">>) of
        [Scheme, HostRest] -> <<Scheme/binary, "://", Bucket/binary, ".", HostRest/binary>>;
        _ -> Endpoint
    end.

add_query(Url, []) ->
    Url;
add_query(Url, Pairs) ->
    Q = iolist_to_binary(lists:join($&, [<<K/binary, $=, V/binary>> || {K, V} <- Pairs])),
    <<Url/binary, "?", Q/binary>>.

do_request(Method, #handle{} = H, Key, Query, Headers, Body) ->
    Url = key_url(H, Key, Query),
    case
        nova_storage_sigv4:sign_request(
            Method,
            Url,
            Headers,
            payload_or_unsigned(Method, Body),
            H#handle.creds,
            #{region => H#handle.region, service => <<"s3">>}
        )
    of
        {ok, SignedHeaders} ->
            HttpHeaders = [{binary_to_list(N), binary_to_list(V)} || {N, V} <- SignedHeaders],
            UrlStr = unicode:characters_to_list(Url),
            httpc_request(Method, UrlStr, HttpHeaders, Body);
        {error, _} = E ->
            E
    end.

payload_or_unsigned(<<"GET">>, _) -> <<>>;
payload_or_unsigned(<<"HEAD">>, _) -> <<>>;
payload_or_unsigned(<<"DELETE">>, _) -> <<>>;
payload_or_unsigned(_, Body) -> Body.

httpc_request(<<"GET">>, Url, Headers, _) ->
    do_httpc(get, {Url, Headers});
httpc_request(<<"HEAD">>, Url, Headers, _) ->
    do_httpc(head, {Url, Headers});
httpc_request(<<"DELETE">>, Url, Headers, _) ->
    do_httpc(delete, {Url, Headers});
httpc_request(<<"PUT">>, Url, Headers, Body) ->
    do_httpc(put, {Url, Headers, content_type_header(Headers), Body});
httpc_request(<<"POST">>, Url, Headers, Body) ->
    do_httpc(post, {Url, Headers, content_type_header(Headers), Body}).

do_httpc(Method, Request) ->
    case
        httpc:request(
            Method,
            Request,
            [{timeout, 30_000}, {connect_timeout, 10_000}],
            [{body_format, binary}]
        )
    of
        {ok, {{_, Status, _}, RespHeaders, RespBody}} ->
            {ok, Status, normalise_headers(RespHeaders), RespBody};
        {error, _} = E ->
            E
    end.

normalise_headers(Headers) ->
    [{list_to_binary(string:lowercase(N)), list_to_binary(V)} || {N, V} <- Headers].

content_type_header(Headers) ->
    case lists:keyfind("content-type", 1, Headers) of
        {_, V} -> V;
        false -> "application/octet-stream"
    end.

body_to_binary(B, _) when is_binary(B) -> B;
body_to_binary(L, _) when is_list(L) -> iolist_to_binary(L);
body_to_binary({stream, ChunkFun}, Timeout) -> collect_stream(ChunkFun, [], Timeout).

collect_stream(Fun, Acc, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() -> Self ! {Ref, Fun()} end),
    Result =
        receive
            {Ref, R} -> R
        after Timeout ->
            unlink(Pid),
            exit(Pid, kill),
            timeout
        end,
    case Result of
        {chunk, Data} -> collect_stream(Fun, [Acc, Data], Timeout);
        eof -> iolist_to_binary(Acc);
        {error, Reason} -> error({stream_error, Reason});
        timeout -> error({stream_timeout, Timeout})
    end.

user_meta_headers(UserMeta) ->
    [{<<"x-amz-meta-", K/binary>>, V} || K := V <- UserMeta].

single_chunk_fun(Body) ->
    Ref = make_ref(),
    PdKey = {?MODULE, sent, Ref},
    fun() ->
        case erlang:get(PdKey) of
            undefined ->
                erlang:put(PdKey, true),
                {chunk, Body};
            true ->
                eof
        end
    end.

build_meta(Key, Size, ContentType, Headers, UserMeta0) ->
    UserMeta =
        case UserMeta0 of
            #{} when map_size(UserMeta0) == 0 -> extract_user_meta(Headers);
            _ -> UserMeta0
        end,
    Base = #{
        key => Key,
        size => Size,
        content_type => ContentType,
        last_modified => erlang:system_time(millisecond),
        user_meta => UserMeta
    },
    case lists:keyfind(<<"etag">>, 1, Headers) of
        false -> Base;
        {_, Etag} -> Base#{etag => Etag}
    end.

extract_user_meta(Headers) ->
    Prefix = <<"x-amz-meta-">>,
    PSize = byte_size(Prefix),
    maps:from_list([
        {binary:part(N, PSize, byte_size(N) - PSize), V}
     || {N, V} <- Headers, binary:longest_common_prefix([N, Prefix]) =:= PSize
    ]).

content_type_of(Headers) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
        false -> <<"application/octet-stream">>;
        {_, V} -> V
    end.

size_of(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        false -> 0;
        {_, V} -> binary_to_integer(V)
    end.
