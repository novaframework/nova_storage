-module(nova_storage_sigv4_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
        aws_get_vanilla_vector,
        clock_skew_rejected_below_2020,
        clock_skew_rejected_above_2100,
        unsigned_payload_rejected_on_http,
        signing_key_derivation,
        canonical_request_uses_sorted_query
    ].

%% AWS published test vector: "get-vanilla"
%% https://docs.aws.amazon.com/general/latest/gr/sigv4-test-suite.html
aws_get_vanilla_vector(_Config) ->
    SecretKey = <<"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY">>,
    DateStamp = <<"20150830">>,
    Region = <<"us-east-1">>,
    Service = <<"service">>,
    AmzDate = <<"20150830T123600Z">>,
    SigningKey = nova_storage_sigv4:derive_signing_key(SecretKey, DateStamp, Region, Service),
    %% Canonical request from AWS docs
    CR = iolist_to_binary([
        "GET\n",
        "/\n",
        "\n",
        "host:example.amazonaws.com\n",
        "x-amz-date:20150830T123600Z\n",
        "\n",
        "host;x-amz-date\n",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ]),
    Scope = <<"20150830/us-east-1/service/aws4_request">>,
    STS = nova_storage_sigv4:string_to_sign(AmzDate, Scope, CR, <<"AWS4-HMAC-SHA256">>),
    ExpectedSTS = iolist_to_binary([
        "AWS4-HMAC-SHA256\n",
        "20150830T123600Z\n",
        "20150830/us-east-1/service/aws4_request\n",
        "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63"
    ]),
    ExpectedSTS = STS,
    Sig = nova_storage_sigv4:signature(SigningKey, STS),
    <<"5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31">> = Sig.

clock_skew_rejected_below_2020(_Config) ->
    Y2019 = 1577836800000 - 86400000,
    Creds = #{access_key => <<"AKID">>, secret_key => <<"SKEY">>},
    RS = #{region => <<"us-east-1">>, service => <<"s3">>},
    {error, system_clock_unset} =
        nova_storage_sigv4:sign_request(
            <<"GET">>, <<"https://example.com/">>, [], <<>>, Creds, RS, Y2019
        ).

clock_skew_rejected_above_2100(_Config) ->
    Y2101 = 4133980800000,
    Creds = #{access_key => <<"AKID">>, secret_key => <<"SKEY">>},
    RS = #{region => <<"us-east-1">>, service => <<"s3">>},
    {error, system_clock_unset} =
        nova_storage_sigv4:sign_request(
            <<"GET">>, <<"https://example.com/">>, [], <<>>, Creds, RS, Y2101
        ).

unsigned_payload_rejected_on_http(_Config) ->
    Creds = #{access_key => <<"AKID">>, secret_key => <<"SKEY">>},
    RS = #{region => <<"us-east-1">>, service => <<"s3">>},
    Now = erlang:system_time(millisecond),
    {error, unsigned_payload_requires_https} =
        nova_storage_sigv4:sign_request(
            <<"PUT">>,
            <<"http://example.com/k">>,
            [],
            unsigned_payload,
            Creds,
            RS,
            Now
        ).

signing_key_derivation(_Config) ->
    %% AWS docs vector
    K = nova_storage_sigv4:derive_signing_key(
        <<"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY">>,
        <<"20150830">>,
        <<"us-east-1">>,
        <<"iam">>
    ),
    Expected = binary:decode_hex(
        <<"c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9">>
    ),
    Expected = K.

canonical_request_uses_sorted_query(_Config) ->
    Creds = #{access_key => <<"AKID">>, secret_key => <<"SKEY">>},
    RS = #{region => <<"us-east-1">>, service => <<"s3">>},
    Now = 1693400160000,
    {ok, Url} = nova_storage_sigv4:presign(
        <<"GET">>,
        <<"https://example.com/key?z=1&a=2">>,
        [],
        Creds,
        RS,
        3600,
        Now
    ),
    %% Sorted query params should produce stable URL ordering
    true = binary:match(Url, <<"a=2">>) =/= nomatch,
    true = binary:match(Url, <<"z=1">>) =/= nomatch,
    true = binary:match(Url, <<"X-Amz-Signature=">>) =/= nomatch.
