# Adapters

Adapters implement the `nova_storage_adapter` behaviour. They own their own
process and the `State` returned from registration is opaque to nova_storage.

## `nova_storage_local`

Filesystem adapter. Stores objects as
`Root/<2-char-shard>/<url-encoded-key>` with a sidecar metadata file.

Configuration:

| Option     | Required | Notes                                       |
| ---------- | -------- | ------------------------------------------- |
| `root`     | yes      | Directory; created on startup.              |
| `max_size` | no       | Per-put byte ceiling. Default `infinity`.   |

Writes are atomic via `tmp`-file + `rename`. A crash between body-rename and
metadata-rename leaves a corrupt object; `get/2` returns `{error, corrupt}`.

`sign_url/3,4` returns `{error, not_supported}` for the local adapter. For
local pre-signing in development, run Minio in a container and use the S3
adapter against it.

## `nova_storage_s3`

S3-compatible adapter. Speaks SigV4 against AWS, Cloudflare R2, Scaleway
Object Storage, Minio, and B2.

| Option              | Required | Notes                                                       |
| ------------------- | -------- | ----------------------------------------------------------- |
| `bucket`            | yes      | Bucket name. One store = one bucket.                        |
| `region`            | yes      | Required for SigV4 even on non-AWS endpoints.               |
| `endpoint`          | no       | Defaults to `https://s3.<region>.amazonaws.com`.            |
| `access_key`        | yes      | Binary or `{env, "VAR_NAME"}`.                              |
| `secret_key`        | yes      | Binary or `{env, "VAR_NAME"}`.                              |
| `addressing_style`  | no       | `virtual` (default) or `path`. Minio needs `path`.          |
| `session_token`     | no       | For temporary credentials.                                  |
| `max_size`          | no       | Per-put byte ceiling. Default `infinity`.                   |

### Provider quick reference

- **AWS:** default settings work.
- **Cloudflare R2:** set `endpoint => <<"https://<account>.r2.cloudflarestorage.com">>`, `region => <<"auto">>`, `addressing_style => virtual`.
- **Scaleway Object:** `endpoint => <<"https://s3.<region>.scw.cloud">>`, region matches Scaleway.
- **Minio (dev):** `endpoint => <<"http://localhost:9000">>` (note: `UNSIGNED-PAYLOAD` will be refused over HTTP — use signed payloads), `addressing_style => path`.

## Writing a new adapter

1. `-behaviour(nova_storage_adapter).`
2. Implement all required callbacks.
3. Register with `nova_storage_registry:register(Name, ?MODULE, State)` from
   `init/1`.
4. The `State` is opaque to `nova_storage` and passed back to each callback.

Adapters may execute work in their own gen_server or in the caller's
process. The contract is the return values, not the topology.
