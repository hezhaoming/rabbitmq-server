%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

%% We use a gen_server simply so that during the terminate/2 call
%% (i.e., during shutdown), we can sync/flush the dets table to disk.

-module(rabbit_recovery_terms).

-behaviour(gen_server).

-export([recover/0,
         upgrade_recovery_indexes/0,
         start_link/0,
         store/2,
         read/1,
         lookup/2,
         clear/0,
         flush/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-rabbit_upgrade({upgrade_recovery_indexes, local, []}).

-ifdef(use_specs).

-spec(recover() -> 'ok').
-spec(upgrade_recovery_indexes() -> 'ok').
-spec(start_link() -> rabbit_types:ok_pid_or_error()).
-spec(store(
        Name  :: file:filename(),
        Terms :: term()) -> rabbit_types:ok_or_error(term())).
-spec(read(
        file:filename()) ->
             rabbit_types:ok_or_error(not_found)).
-spec(lookup(
        file:filename(),
        [{file:filename(), [term()]}]) ->
             {'ok', [term()]} | 'false').
-spec(clear() -> 'ok').

-endif. % use_specs

-include("rabbit.hrl").
-define(SERVER, ?MODULE).

recover() ->
    case supervisor:start_child(rabbit_sup,
                                {?SERVER, {?MODULE, start_link, []},
                                 permanent, ?MAX_WAIT, worker,
                                 [?SERVER]}) of
        {ok, _}                       -> ok;
        {error, {already_started, _}} -> ok;
        {error, _}=Err                -> Err
    end.

upgrade_recovery_indexes() ->
    create_table(),
    try
        QueuesDir = filename:join(rabbit_mnesia:dir(), "queues"),
        DotFiles = filelib:fold_files(QueuesDir, "clean.dot", true,
                                      fun(F, Acc) -> [F|Acc] end, []),
        [begin
             {ok, Terms} = rabbit_file:read_term_file(File),
             ok = store(File, Terms),
             case file:delete(File) of
                 {error, E} ->
                     rabbit_log:warning("Unable to delete recovery index"
                                        "~s during upgrade: ~p~n", [File, E]);
                 ok ->
                     ok
             end
         end || File <- DotFiles],
        ok
    after
        flush()
    end.

start_link() ->
    gen_server:start_link(?MODULE, [], []).

store(Name, Terms) ->
    dets:insert(?MODULE, {scrub(Name), Terms}).

read(Name) ->
    case dets:lookup(?MODULE, scrub(Name)) of
        [{_, Terms}] -> {ok, Terms};
        _            -> {error, not_found}
    end.

lookup(RecoveryKey, RecoveryTerms) ->
    lists:keyfind(to_dirname(RecoveryKey), 1, RecoveryTerms).

clear() ->
    dets:delete_all_objects(?MODULE),
    flush().

init(_) ->
    process_flag(trap_exit, true),
    create_table(),
    {ok, undefined}.

handle_call(Msg, _, State) ->
    {stop, {unexpected_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok = flush(),
    ok = dets:close(?MODULE).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

flush() ->
    dets:sync(?MODULE).

create_table() ->
    File = dets_filename(),
    {ok, _} = dets:open_file(?MODULE, [{file, File},
                                       {ram_file, true},
                                       {auto_save, infinity}]).

scrub(Name) ->
    filename:basename(Name).

dets_filename() ->
    to_dirname("recovery.dets").

to_dirname(FileName) ->
    filename:join([rabbit_mnesia:dir(), "queues", FileName]).

