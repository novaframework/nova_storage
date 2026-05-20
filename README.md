# nova_storage

Object/file storage abstraction for the Nova ecosystem.

`nova_storage` is **not** a dependency of Nova core and must never become one.

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
            access_key => "S3_ACCESS_KEY",
            secret_key => "S3_SECRET_KEY"
        }
    }}
]}.

%% application code
{ok, Meta} = nova_storage:put(avatars, <<"alice.png">>, PngBytes,
                              #{content_type => <<"image/png">>}),
{ok, Body, _} = nova_storage:get(avatars, <<"alice.png">>),
{ok, Url} = nova_storage:sign_url(uploads, <<"some/key">>, get,
                                  #{expires_in => 3600}).
```

## Adapters

| Adapter              | Status |
| -------------------- | ------ |
| `nova_storage_local` | v0.1   |
| `nova_storage_s3`    | v0.1   |

The S3 adapter works against AWS, Cloudflare R2, Scaleway Object, Minio, B2.

## Scope

`nova_storage` is intentionally narrow: bytes in, bytes out, signed URLs,
listing. Audit logging, encryption-at-rest, and image transforms are
deliberately out of scope.

## Build

```sh
rebar3 compile
rebar3 dialyzer
rebar3 xref
```

## Test

```sh
rebar3 ct
rebar3 eunit
rebar3 mutate
```

## Documentation

See the [guides](guides/) directory.

## License

Apache-2.0.
