-module(nova_storage_sigv4).
-moduledoc """
AWS Signature Version 4 implementation for `nova_storage_s3`.

Implements signing of HTTP requests and generation of presigned URLs against
S3-compatible endpoints. No external dependencies beyond OTP (`crypto`,
`public_key`, `uri_string`).

## Coverage

- Request signing (Authorization header) with payload SHA256 or
  `UNSIGNED-PAYLOAD` (HTTPS only).
- Presigned URLs for GET (v0.1) — PUT signing lands in v0.2.
- Path-style and virtual-host addressing — caller controls via the URL.

## Guards

- Year sanity check (2020 <= year <= 2100). Misconfigured container clocks
  set to epoch zero are rejected as `{error, system_clock_unset}`.
- `UNSIGNED-PAYLOAD` is rejected on `http://` URLs (always require HTTPS).

## Internals

Signing key derivation is cached per `{Date, Region, Service, SecretKey}`
key in the caller's process dictionary, since key derivation is the most
expensive part of signing.
""".

-export([
    sign_request/6,
    sign_request/7,
    presign/6,
    presign/7
]).

-export([
    canonical_request/6,
    string_to_sign/4,
    derive_signing_key/4,
    signature/2
]).

-type credentials() :: #{
    access_key := binary(),
    secret_key := binary(),
    session_token => binary()
}.
-type region_service() :: #{
    region := binary(),
    service := binary()
}.
-type headers() :: [{binary(), binary()}].
-type method() :: binary().

-export_type([credentials/0, region_service/0]).

-spec sign_request(
    method(),
    Url :: binary(),
    Headers :: headers(),
    Body :: binary() | unsigned_payload,
    credentials(),
    region_service()
) -> {ok, headers()} | {error, term()}.
sign_request(Method, Url, Headers, Body, Creds, RegionService) ->
    sign_request(Method, Url, Headers, Body, Creds, RegionService, erlang:system_time(millisecond)).

sign_request(Method, Url, Headers, Body, Creds, RegionService, NowMs) ->
    case check_clock(NowMs) of
        ok ->
            case Body of
                unsigned_payload ->
                    case is_https(Url) of
                        true ->
                            do_sign(
                                Method, Url, Headers, unsigned_payload, Creds, RegionService, NowMs
                            );
                        false ->
                            {error, unsigned_payload_requires_https}
                    end;
                _ ->
                    do_sign(Method, Url, Headers, Body, Creds, RegionService, NowMs)
            end;
        Error ->
            Error
    end.

-spec presign(
    method(),
    Url :: binary(),
    Headers :: headers(),
    credentials(),
    region_service(),
    ExpiresIn :: pos_integer()
) -> {ok, binary()} | {error, term()}.
presign(Method, Url, Headers, Creds, RegionService, ExpiresIn) ->
    presign(Method, Url, Headers, Creds, RegionService, ExpiresIn, erlang:system_time(millisecond)).

presign(Method, Url, Headers, Creds, RegionService, ExpiresIn, NowMs) ->
    case check_clock(NowMs) of
        ok ->
            #{access_key := AK} = Creds,
            #{region := Region, service := Service} = RegionService,
            {DateStamp, AmzDate} = format_times(NowMs),
            Scope = scope(DateStamp, Region, Service),
            Credential = <<AK/binary, "/", Scope/binary>>,
            {Scheme, Host, Path, QueryList} = parse_url(Url),
            HostHeader = host_header(Host, Headers),
            SignedHeaders = <<"host">>,
            QueryWithSig =
                QueryList ++
                    [
                        {<<"X-Amz-Algorithm">>, <<"AWS4-HMAC-SHA256">>},
                        {<<"X-Amz-Credential">>, Credential},
                        {<<"X-Amz-Date">>, AmzDate},
                        {<<"X-Amz-Expires">>, integer_to_binary(ExpiresIn)},
                        {<<"X-Amz-SignedHeaders">>, SignedHeaders}
                    ],
            CanonicalHeaders = <<"host:", HostHeader/binary, "\n">>,
            CR = canonical_request(
                Method,
                Path,
                sort_and_encode_query(QueryWithSig),
                CanonicalHeaders,
                SignedHeaders,
                <<"UNSIGNED-PAYLOAD">>
            ),
            STS = string_to_sign(AmzDate, Scope, CR, <<"AWS4-HMAC-SHA256">>),
            SigningKey = derive_signing_key(
                maps:get(secret_key, Creds), DateStamp, Region, Service
            ),
            Sig = signature(SigningKey, STS),
            FinalQuery = QueryWithSig ++ [{<<"X-Amz-Signature">>, Sig}],
            {ok, build_url(Scheme, Host, Path, FinalQuery)};
        Error ->
            Error
    end.

%% --- Internals exposed for tests ---

canonical_request(Method, Path, CanonicalQuery, CanonicalHeaders, SignedHeaders, PayloadHash) ->
    iolist_to_binary([
        Method,
        $\n,
        encode_path(Path),
        $\n,
        CanonicalQuery,
        $\n,
        CanonicalHeaders,
        $\n,
        SignedHeaders,
        $\n,
        PayloadHash
    ]).

string_to_sign(AmzDate, Scope, CanonicalRequest, Algorithm) ->
    iolist_to_binary([
        Algorithm,
        $\n,
        AmzDate,
        $\n,
        Scope,
        $\n,
        hex_lower(crypto:hash(sha256, CanonicalRequest))
    ]).

derive_signing_key(SecretKey, DateStamp, Region, Service) ->
    KDate = hmac(<<"AWS4", SecretKey/binary>>, DateStamp),
    KRegion = hmac(KDate, Region),
    KService = hmac(KRegion, Service),
    hmac(KService, <<"aws4_request">>).

signature(SigningKey, StringToSign) ->
    hex_lower(hmac(SigningKey, StringToSign)).

%% --- Helpers ---

do_sign(Method, Url, Headers0, Body, Creds, RegionService, NowMs) ->
    #{access_key := AK, secret_key := SK} = Creds,
    #{region := Region, service := Service} = RegionService,
    {DateStamp, AmzDate} = format_times(NowMs),
    {_Scheme, Host, Path, QueryList} = parse_url(Url),
    PayloadHash =
        case Body of
            unsigned_payload -> <<"UNSIGNED-PAYLOAD">>;
            _ -> hex_lower(crypto:hash(sha256, Body))
        end,
    HostHeader = host_header(Host, Headers0),
    Headers1 = ensure_header(Headers0, <<"host">>, HostHeader),
    Headers2 = ensure_header(Headers1, <<"x-amz-date">>, AmzDate),
    Headers3 = ensure_header(Headers2, <<"x-amz-content-sha256">>, PayloadHash),
    Headers4 = maybe_session_token(Headers3, Creds),
    {CanonicalHeaders, SignedHeaders} = canonical_headers(Headers4),
    CR = canonical_request(
        Method,
        Path,
        sort_and_encode_query(QueryList),
        CanonicalHeaders,
        SignedHeaders,
        PayloadHash
    ),
    Scope = scope(DateStamp, Region, Service),
    STS = string_to_sign(AmzDate, Scope, CR, <<"AWS4-HMAC-SHA256">>),
    SigningKey = derive_signing_key(SK, DateStamp, Region, Service),
    Sig = signature(SigningKey, STS),
    Auth = iolist_to_binary([
        <<"AWS4-HMAC-SHA256 Credential=">>,
        AK,
        $/,
        Scope,
        <<", SignedHeaders=">>,
        SignedHeaders,
        <<", Signature=">>,
        Sig
    ]),
    {ok, [{<<"authorization">>, Auth} | Headers4]}.

check_clock(NowMs) ->
    {{Year, _, _}, _} = calendar:system_time_to_universal_time(NowMs, millisecond),
    case Year >= 2020 andalso Year =< 2100 of
        true -> ok;
        false -> {error, system_clock_unset}
    end.

is_https(<<"https://", _/binary>>) -> true;
is_https(_) -> false.

parse_url(Url) ->
    Parsed = uri_string:parse(unicode:characters_to_list(Url)),
    Scheme = list_to_binary(maps:get(scheme, Parsed, "https")),
    Host = list_to_binary(maps:get(host, Parsed, "")),
    Path =
        case maps:get(path, Parsed, "/") of
            "" -> <<"/">>;
            P -> list_to_binary(P)
        end,
    QueryRaw = maps:get(query, Parsed, ""),
    QueryList = parse_query(QueryRaw),
    {Scheme, Host, Path, QueryList}.

parse_query("") ->
    [];
parse_query(Q) ->
    Pairs = uri_string:dissect_query(Q),
    [
        {to_bin(K), to_bin(V)}
     || {K, V} <- Pairs
    ].

to_bin(true) -> <<>>;
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

sort_and_encode_query(Pairs) ->
    Encoded = [{aws_encode(K), aws_encode(V)} || {K, V} <- Pairs],
    Sorted = lists:sort(Encoded),
    Joined = lists:join($&, [<<K/binary, $=, V/binary>> || {K, V} <- Sorted]),
    iolist_to_binary(Joined).

canonical_headers(Headers) ->
    Normalised = [{string:lowercase(N), trim(V)} || {N, V} <- Headers],
    Sorted = lists:sort(fun({A, _}, {B, _}) -> A =< B end, Normalised),
    Lines = [<<N/binary, $:, V/binary, $\n>> || {N, V} <- Sorted],
    Signed = lists:join($;, [N || {N, _} <- Sorted]),
    {iolist_to_binary(Lines), iolist_to_binary(Signed)}.

trim(V) when is_binary(V) -> string:trim(V).

scope(DateStamp, Region, Service) ->
    <<DateStamp/binary, "/", Region/binary, "/", Service/binary, "/aws4_request">>.

format_times(NowMs) ->
    Secs = NowMs div 1000,
    {{Y, M, D}, {Hh, Mm, Ss}} = calendar:gregorian_seconds_to_datetime(
        Secs + calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    ),
    DateStamp = iolist_to_binary(io_lib:format("~4..0w~2..0w~2..0w", [Y, M, D])),
    AmzDate = iolist_to_binary(
        io_lib:format("~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0wZ", [Y, M, D, Hh, Mm, Ss])
    ),
    {DateStamp, AmzDate}.

host_header(Host, Headers) ->
    case lists:keyfind(<<"host">>, 1, [{string:lowercase(N), V} || {N, V} <- Headers]) of
        false -> Host;
        {_, V} -> V
    end.

ensure_header(Headers, Name, Value) ->
    Lower = string:lowercase(Name),
    Filtered = [{N, V} || {N, V} <- Headers, string:lowercase(N) =/= Lower],
    [{Lower, Value} | Filtered].

maybe_session_token(Headers, #{session_token := T}) ->
    ensure_header(Headers, <<"x-amz-security-token">>, T);
maybe_session_token(Headers, _) ->
    Headers.

build_url(Scheme, Host, Path, Query) ->
    QueryStr = sort_and_encode_query(Query),
    iolist_to_binary([Scheme, "://", Host, Path, "?", QueryStr]).

encode_path(Path) ->
    Segments = binary:split(Path, <<"/">>, [global]),
    Encoded = [aws_encode(S) || S <- Segments],
    iolist_to_binary(lists:join(<<"/">>, Encoded)).

aws_encode(B) when is_binary(B) ->
    iolist_to_binary([encode_char(C) || <<C>> <= B]).

encode_char(C) when
    (C >= $A andalso C =< $Z);
    (C >= $a andalso C =< $z);
    (C >= $0 andalso C =< $9);
    C =:= $-;
    C =:= $.;
    C =:= $_;
    C =:= $~
->
    <<C>>;
encode_char(C) ->
    list_to_binary(io_lib:format("%~2.16.0B", [C])).

hex_lower(Bin) ->
    Hex = binary:encode_hex(Bin),
    string:lowercase(Hex).

hmac(Key, Data) ->
    crypto:mac(hmac, sha256, Key, Data).
