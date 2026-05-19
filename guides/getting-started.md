# Getting Started

## Installation

```erlang
{deps, [
    {nova_storage, {git, "https://github.com/novaframework/nova_storage.git", {branch, "main"}}}
]}.
```

## Configure stores

```erlang
{nova_storage, [{stores, #{
    avatars => #{
        adapter => nova_storage_local,
        root => "/var/data/avatars",
        max_size => 5_000_000
    },
    uploads => #{
        adapter => nova_storage_s3,
        bucket => <<"my-uploads">>,
        region => <<"eu-west-1">>,
        endpoint => <<"https://s3.eu-west-1.amazonaws.com">>,
        access_key => "S3_ACCESS_KEY",
        secret_key => "S3_SECRET_KEY",
        addressing_style => virtual
    }
}}]}.
```

One supervised process per store starts under `nova_storage_sup`.

## Put

```erlang
{ok, Meta} = nova_storage:put(uploads, <<"docs/policy.pdf">>, PdfBytes,
                              #{content_type => <<"application/pdf">>}).
```

`content_type` is **required**. There is no extension sniffing.

## Streaming put

```erlang
{ok, Meta} = nova_storage:put(uploads, <<"big.zip">>,
    {stream, fun() ->
        case read_next_chunk() of
            <<>> -> eof;
            Chunk -> {chunk, Chunk}
        end
    end},
    #{content_type => <<"application/zip">>}).
```

The chunk fun is called by the adapter, in the adapter's process,
synchronously. Producers must not block waiting on the adapter.

## Get

```erlang
{ok, Body, Meta} = nova_storage:get(uploads, <<"docs/policy.pdf">>).
{ok, Meta} = nova_storage:head(uploads, <<"docs/policy.pdf">>).
true = nova_storage:exists(uploads, <<"docs/policy.pdf">>).
```

## Streaming get

```erlang
{ok, ChunkFun, _Meta} = nova_storage:get_stream(uploads, <<"big.zip">>),
loop(ChunkFun).
```

**Caveat:** the S3 adapter currently buffers the whole response. For objects
> 32 MB, use `sign_url/3,4` and have the client transfer directly.

## Copy and delete

```erlang
{ok, _} = nova_storage:copy(uploads, <<"src">>, <<"dst">>),
ok = nova_storage:delete(uploads, <<"src">>).
```

## Sign URL (GET only in v0.1)

```erlang
{ok, Url} = nova_storage:sign_url(uploads, <<"reports/q1.pdf">>, get,
                                  #{expires_in => 600}).
```

PUT signing lands in v0.2.

## List

```erlang
{ok, Metas, Cursor} = nova_storage:list(uploads, <<"reports/">>, #{limit => 100}).

case Cursor of
    done -> ok;
    Next -> nova_storage:list(uploads, <<"reports/">>, #{cursor => Next, limit => 100})
end.
```
