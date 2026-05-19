# SigV4 Internals

`nova_storage_sigv4` is a from-scratch SigV4 implementation with no
non-stdlib dependencies. It signs requests and generates presigned URLs.

## Why not a third-party library?

The two viable options were vendored or hand-rolled. SigV4 is well-specified,
about 150 lines, and stable. Vendoring meant inheriting `hackney` and an
incomplete library marked alpha. Rolling our own keeps zero new dependencies
and full control over edge cases (R2 quirks, Scaleway endpoints, path-style
addressing).

## Guards

- **Year sanity check.** Refuses to sign if the system clock reports a year
  outside `2020 <= year <= 2100`. Catches container clocks set to epoch
  zero. AWS rejects requests with >15min skew; this catches the gross case.
- **UNSIGNED-PAYLOAD over HTTPS only.** Returns
  `{error, unsigned_payload_requires_https}` for `http://` URLs.

## URL encoding rules

The #1 SigV4 bug is URL encoding. `nova_storage_sigv4:aws_encode/1`
implements AWS's exact rules:

- Unreserved characters `[A-Za-z0-9-._~]` pass through unchanged.
- Every other byte becomes `%HH` in upper case hex.
- The canonical URI applies `aws_encode/1` per path segment; the canonical
  query string applies `aws_encode/1` to keys and values independently.

`/` is preserved as a path separator (encoded per segment, then joined),
not double-encoded.

## Property tests

`test/nova_storage_sigv4_SUITE.erl` exercises the implementation against
published AWS test vectors:

- `aws_get_vanilla_vector` — the canonical GET / no-query case.
- `signing_key_derivation` — verifies the four-stage HMAC chain.
- `clock_skew_rejected_below_2020` / `_above_2100` — the year guard.
- `unsigned_payload_rejected_on_http` — the HTTPS guard.
- `canonical_request_uses_sorted_query` — query parameter ordering.

Adding more vectors is welcome. The full AWS test suite is at
<https://docs.aws.amazon.com/general/latest/gr/sigv4-test-suite.html>.
