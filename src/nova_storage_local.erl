-module(nova_storage_local).
-moduledoc """
Filesystem adapter for `nova_storage`.

Stores objects as `Root/<2-char-shard>/<url-encoded-key>` with a sidecar
metadata file `<file>.meta` containing JSON.

## Atomicity

Writes are atomic via the following sequence:

1. Write metadata to `<file>.meta.tmp`, fsync.
2. Write body to `<file>.tmp`, fsync.
3. Rename body file (atomic on same filesystem).
4. Rename metadata file (atomic on same filesystem).

A crash between step 3 and 4 leaves a body without metadata; `get/2` returns
`{error, corrupt}` for these. A crash before step 3 leaves only `.tmp` files
which are reaped on startup.

## Streaming

`put` with `{stream, ChunkFun}` pulls chunks synchronously and writes each
to the body file. `get_stream` opens the file and returns a chunk fun that
reads 64KiB blocks until EOF.

## Signed URLs

`nova_storage_local` does not support `sign_url`; returns `{error, not_supported}`.
For local pre-signing in dev, use the S3 adapter against a Minio container.
""".

-behaviour(gen_server).
-behaviour(nova_storage_adapter).

-export([start_link/2]).
-export([put/4, get/2, get_stream/2, head/2, delete/2, copy/3, exists/2, sign_url/4, list/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHUNK_SIZE, 65_536).

-record(state, {name :: atom(), root :: file:filename_all()}).
-record(handle, {name :: atom(), root :: binary()}).

start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

put(Key, Body, Opts, #handle{root = Root}) ->
    Path = object_path(Root, Key),
    MetaPath = meta_path(Path),
    ok = ensure_dir(Path),
    BodyTmp = <<Path/binary, ".tmp">>,
    MetaTmp = <<MetaPath/binary, ".tmp">>,
    ContentType = maps:get(content_type, Opts, <<"application/octet-stream">>),
    UserMeta = maps:get(user_meta, Opts, #{}),
    ok = write_meta(MetaTmp, Key, ContentType, UserMeta, 0),
    Size = write_body(BodyTmp, Body, maps:get(chunk_timeout, Opts, 30_000)),
    ok = write_meta(MetaTmp, Key, ContentType, UserMeta, Size),
    ok = file:rename(BodyTmp, Path),
    ok = file:rename(MetaTmp, MetaPath),
    {ok, build_meta(Key, Size, ContentType, etag_of(Path), UserMeta)}.

get(Key, #handle{root = Root}) ->
    Path = object_path(Root, Key),
    case read_meta(meta_path(Path)) of
        {ok, Meta} ->
            case file:read_file(Path) of
                {ok, Body} -> {ok, Body, Meta};
                {error, enoent} -> {error, corrupt};
                {error, _} = E -> E
            end;
        not_found ->
            not_found
    end.

get_stream(Key, #handle{root = Root}) ->
    Path = object_path(Root, Key),
    case read_meta(meta_path(Path)) of
        {ok, Meta} ->
            case file:open(Path, [read, binary, raw]) of
                {ok, IoDev} ->
                    Fun = fun() ->
                        case file:read(IoDev, ?CHUNK_SIZE) of
                            {ok, Data} ->
                                {chunk, Data};
                            eof ->
                                _ = file:close(IoDev),
                                eof;
                            {error, _} = ReadErr ->
                                _ = file:close(IoDev),
                                ReadErr
                        end
                    end,
                    {ok, Fun, Meta};
                {error, enoent} ->
                    {error, corrupt};
                {error, _} = E ->
                    E
            end;
        not_found ->
            not_found
    end.

head(Key, #handle{root = Root}) ->
    Path = object_path(Root, Key),
    read_meta(meta_path(Path)).

delete(Key, #handle{root = Root}) ->
    Path = object_path(Root, Key),
    _ = file:delete(meta_path(Path)),
    _ = file:delete(Path),
    ok.

copy(Source, Dest, #handle{root = Root}) ->
    SrcPath = object_path(Root, Source),
    DestPath = object_path(Root, Dest),
    ok = ensure_dir(DestPath),
    case read_meta(meta_path(SrcPath)) of
        {ok, Meta} ->
            case file:copy(SrcPath, DestPath) of
                {ok, _} ->
                    DestMeta = Meta#{key => Dest},
                    _ = file:write_file(meta_path(DestPath), encode_meta(DestMeta)),
                    {ok, DestMeta};
                {error, _} = E ->
                    E
            end;
        not_found ->
            {error, not_found}
    end.

exists(Key, #handle{root = Root}) ->
    Path = object_path(Root, Key),
    filelib:is_regular(meta_path(Path)).

sign_url(_Key, _Method, _Opts, _State) ->
    {error, not_supported}.

list(Prefix, Opts, #handle{root = Root}) ->
    Limit = maps:get(limit, Opts, 1000),
    Cursor = maps:get(cursor, Opts, undefined),
    AllKeys = walk_keys(Root),
    Filtered = [K || K <- AllKeys, has_prefix(K, Prefix)],
    AfterCursor = drop_through_cursor(Filtered, Cursor),
    {Page, Rest} = take(AfterCursor, Limit),
    Metas = lists:filtermap(
        fun(K) ->
            case read_meta(meta_path(object_path(Root, K))) of
                {ok, M} -> {true, M};
                _ -> false
            end
        end,
        Page
    ),
    NextCursor =
        case Rest of
            [] -> done;
            _ -> lists:last(Page)
        end,
    {ok, Metas, NextCursor}.

init({Name, Opts}) ->
    Root = unicode:characters_to_binary(maps:get(root, Opts)),
    ok = filelib:ensure_path(Root),
    _ = reap_tmp_files(Root),
    Handle = #handle{name = Name, root = Root},
    ok = nova_storage_registry:register(Name, ?MODULE, Handle),
    {ok, #state{name = Name, root = Root}}.

handle_call(_, _, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.

%% Internal

object_path(Root, Key) ->
    Encoded = encode_key(Key),
    Shard = shard_for(Key),
    filename:join([Root, Shard, Encoded]).

meta_path(Path) ->
    <<Path/binary, ".meta">>.

shard_for(Key) ->
    <<H:8, _/binary>> = crypto:hash(sha256, Key),
    list_to_binary(io_lib:format("~2.16.0b", [H])).

encode_key(Key) ->
    iolist_to_binary([encode_byte(B) || <<B>> <= Key]).

encode_byte(B) when
    (B >= $A andalso B =< $Z);
    (B >= $a andalso B =< $z);
    (B >= $0 andalso B =< $9);
    B =:= $-;
    B =:= $.;
    B =:= $_;
    B =:= $~
->
    <<B>>;
encode_byte(B) ->
    list_to_binary(io_lib:format("%~2.16.0B", [B])).

ensure_dir(Path) ->
    filelib:ensure_dir(Path).

write_meta(Path, Key, ContentType, UserMeta, Size) ->
    Meta = build_meta(Key, Size, ContentType, undefined, UserMeta),
    file:write_file(Path, encode_meta(Meta)).

build_meta(Key, Size, ContentType, Etag, UserMeta) ->
    Base = #{
        key => Key,
        size => Size,
        content_type => ContentType,
        last_modified => erlang:system_time(millisecond),
        user_meta => UserMeta
    },
    case Etag of
        undefined -> Base;
        _ -> Base#{etag => Etag}
    end.

encode_meta(Meta) ->
    iolist_to_binary(json:encode(Meta)).

read_meta(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try json:decode(Bin) of
                Map when is_map(Map) -> {ok, atomize_meta(Map)};
                _ -> {error, corrupt}
            catch
                _:_ -> {error, corrupt}
            end;
        {error, enoent} ->
            not_found;
        {error, _} = E ->
            E
    end.

atomize_meta(Map) ->
    maps:fold(
        fun
            (K, V, Acc) when is_binary(K) ->
                Acc#{binary_to_atom(K) => V};
            (K, V, Acc) ->
                Acc#{K => V}
        end,
        #{},
        Map
    ).

write_body(Path, Body, _Timeout) when is_binary(Body); is_list(Body) ->
    ok = file:write_file(Path, Body),
    iolist_size(Body);
write_body(Path, {stream, ChunkFun}, Timeout) ->
    {ok, IoDev} = file:open(Path, [write, binary, raw]),
    Size = stream_loop(IoDev, ChunkFun, 0, Timeout),
    ok = file:sync(IoDev),
    ok = file:close(IoDev),
    Size.

stream_loop(IoDev, ChunkFun, Acc, Timeout) ->
    case timed_call(ChunkFun, Timeout) of
        {chunk, Data} ->
            ok = file:write(IoDev, Data),
            stream_loop(IoDev, ChunkFun, Acc + byte_size(Data), Timeout);
        eof ->
            Acc;
        {error, Reason} ->
            error({stream_error, Reason});
        timeout ->
            error({stream_timeout, Timeout})
    end.

timed_call(Fun, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() -> Self ! {Ref, Fun()} end),
    receive
        {Ref, R} -> R
    after Timeout ->
        unlink(Pid),
        exit(Pid, kill),
        timeout
    end.

etag_of(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Hex = binary:encode_hex(crypto:hash(md5, Bin)),
            <<"\"", Hex/binary, "\"">>;
        _ ->
            <<>>
    end.

reap_tmp_files(Root) ->
    RootStr = unicode:characters_to_list(Root),
    filelib:fold_files(
        RootStr,
        ".*\\.tmp$",
        true,
        fun(F, _) ->
            _ = file:delete(F),
            ok
        end,
        ok
    ).

walk_keys(Root) ->
    Pattern = unicode:characters_to_list([Root, "/*/*.meta"]),
    Files = filelib:wildcard(Pattern),
    [decode_key_from_meta(F) || F <- Files].

decode_key_from_meta(MetaPath) ->
    case file:read_file(MetaPath) of
        {ok, Bin} ->
            case json:decode(Bin) of
                #{<<"key">> := K} -> K;
                _ -> <<>>
            end;
        _ ->
            <<>>
    end.

has_prefix(_Key, <<>>) -> true;
has_prefix(Key, Prefix) -> binary:longest_common_prefix([Key, Prefix]) =:= byte_size(Prefix).

drop_through_cursor(Keys, undefined) ->
    lists:sort(Keys);
drop_through_cursor(Keys, Cursor) ->
    Sorted = lists:sort(Keys),
    lists:dropwhile(fun(K) -> K =< Cursor end, Sorted).

take([], _) -> {[], []};
take(L, N) -> lists:split(min(N, length(L)), L).
