-module(nova_storage_s3_xml).
-moduledoc """
Minimal XML parsing for S3 responses.

Currently parses `ListObjectsV2` results. Uses stdlib `xmerl` so no extra
deps. Intentionally narrow — extracts only the fields nova_storage needs.
""".

-export([parse_list_v2/1]).

-include_lib("xmerl/include/xmerl.hrl").

-spec parse_list_v2(binary()) -> {[map()], binary() | done}.
parse_list_v2(Body) ->
    {Doc, _} = xmerl_scan:string(unicode:characters_to_list(Body)),
    Contents = xmerl_xpath:string("/ListBucketResult/Contents", Doc),
    Metas = [content_to_meta(C) || C <- Contents],
    NextCursor =
        case xmerl_xpath:string("/ListBucketResult/NextContinuationToken/text()", Doc) of
            [#xmlText{value = V}] -> list_to_binary(V);
            _ -> done
        end,
    {Metas, NextCursor}.

content_to_meta(Content) ->
    Key = text(Content, "Key"),
    Size =
        case text(Content, "Size") of
            <<>> -> 0;
            V -> binary_to_integer(V)
        end,
    Etag = text(Content, "ETag"),
    Last = text(Content, "LastModified"),
    Base = #{
        key => Key,
        size => Size,
        last_modified => parse_iso8601(Last),
        user_meta => #{}
    },
    case Etag of
        <<>> -> Base;
        _ -> Base#{etag => Etag}
    end.

text(Node, Tag) ->
    case xmerl_xpath:string(Tag ++ "/text()", Node) of
        [#xmlText{value = V}] -> list_to_binary(V);
        _ -> <<>>
    end.

parse_iso8601(<<>>) ->
    0;
parse_iso8601(Bin) ->
    try
        S = unicode:characters_to_list(Bin),
        [Date, RestZ] = string:split(S, "T"),
        Time =
            case string:trim(RestZ, trailing, "Z") of
                T -> T
            end,
        [Y, Mo, D] = [list_to_integer(X) || X <- string:split(Date, "-", all)],
        [H, Mi, Sec] = parse_time_parts(Time),
        DT = {{Y, Mo, D}, {H, Mi, Sec}},
        Sec0 = calendar:datetime_to_gregorian_seconds(DT),
        Epoch0 = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
        (Sec0 - Epoch0) * 1000
    catch
        _:_ -> 0
    end.

parse_time_parts(T) ->
    Clean = lists:takewhile(fun(C) -> C =/= $. end, T),
    [list_to_integer(X) || X <- string:split(Clean, ":", all)].
