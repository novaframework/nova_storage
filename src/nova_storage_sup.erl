-module(nova_storage_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/0, init/1, start_store/2, stop_store/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    Registry = #{
        id => nova_storage_registry,
        start => {nova_storage_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    Stores = configured_stores(),
    {ok, {SupFlags, [Registry | Stores]}}.

start_store(Name, Spec) ->
    supervisor:start_child(?MODULE, child_spec(Name, Spec)).

stop_store(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok -> supervisor:delete_child(?MODULE, Name);
        Error -> Error
    end.

configured_stores() ->
    Stores = application:get_env(nova_storage, stores, #{}),
    maps:fold(fun(Name, Spec, Acc) -> [child_spec(Name, Spec) | Acc] end, [], Stores).

child_spec(Name, Spec) ->
    Adapter = maps:get(adapter, Spec),
    #{
        id => Name,
        start => {Adapter, start_link, [Name, Spec]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.
