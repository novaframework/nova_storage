# Telemetry

`nova_storage` emits telemetry events when the optional `telemetry`
application is available at runtime. The dependency is not required; calls
without telemetry loaded silently no-op.

## Events

For each operation `Op` in `put | get | get_stream | head | delete | copy`:

| Event                                | Measurements           | Metadata                                              |
| ------------------------------------ | ---------------------- | ----------------------------------------------------- |
| `[nova_storage, Op, start]`          | `system_time`          | `store`, `adapter`, `key`                             |
| `[nova_storage, Op, stop]`           | `duration` (native)    | `store`, `adapter`, `key`, `result`                   |
| `[nova_storage, Op, exception]`      | `duration` (native)    | `store`, `adapter`, `key`, `kind`, `reason`, `stacktrace` |

`result` is `ok | not_found | error | other`.

`duration` is in native units; use `erlang:convert_time_unit/3` to convert.

## Example handler

```erlang
telemetry:attach_many(
    storage_logger,
    [
        [nova_storage, put, stop],
        [nova_storage, get, stop],
        [nova_storage, delete, stop]
    ],
    fun(Event, #{duration := D}, #{store := Store, result := R}, _) ->
        logger:info(#{
            event => storage_op,
            op => lists:last(Event),
            store => Store,
            result => R,
            ms => erlang:convert_time_unit(D, native, millisecond)
        })
    end,
    no_state
).
```

## OpenTelemetry

Configure your own OTel pipeline to subscribe to these
`[nova_storage, ...]` events.
