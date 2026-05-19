-module(nova_storage_app).
-moduledoc false.

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    nova_storage_sup:start_link().

stop(_State) ->
    ok.
