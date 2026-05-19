-module(nova_storage_registry).
-moduledoc false.

-behaviour(gen_server).

-export([start_link/0, register/3, unregister/1, lookup/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, nova_storage_registry).

-record(state, {monitors = #{} :: #{reference() => atom()}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Name, Adapter, State) ->
    gen_server:call(?MODULE, {register, Name, Adapter, State, self()}).

unregister(Name) ->
    gen_server:call(?MODULE, {unregister, Name}).

lookup(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Adapter, State}] -> {ok, Adapter, State};
        [] -> {error, not_found}
    end.

list() ->
    [Name || {Name, _, _} <- ets:tab2list(?TABLE)].

init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({register, Name, Adapter, State, Pid}, _From, S = #state{monitors = M}) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(?TABLE, {Name, Adapter, State}),
    {reply, ok, S#state{monitors = M#{Ref => Name}}};
handle_call({unregister, Name}, _From, S) ->
    ets:delete(?TABLE, Name),
    {reply, ok, S};
handle_call(_, _, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) ->
    {noreply, S}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, S = #state{monitors = M}) ->
    case maps:take(Ref, M) of
        {Name, M2} ->
            ets:delete(?TABLE, Name),
            {noreply, S#state{monitors = M2}};
        error ->
            {noreply, S}
    end;
handle_info(_, S) ->
    {noreply, S}.
