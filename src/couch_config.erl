% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% Reads CouchDB's ini file and gets queried for configuration parameters.
% This module is initialized with a list of ini files that it consecutively
% reads Key/Value pairs from and saves them in an ets table. If more an one
% ini file is specified, the last one is used to write changes that are made
% with store/2 back to that ini file.

-module(couch_config).
-behaviour(gen_server).

-export([start_link/1, stop/0]).
-export([all/0, get/1, get/2, get/3, set/3, set/4, delete/2, delete/3]).
-export([register/1, register/2]).
-export([parse_ini_file/1]).

-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-record(config, {
    notify_funs=[],
    write_filename=undefined
}).


start_link(IniFiles) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, IniFiles, []).

stop() ->
    gen_server:cast(?MODULE, stop).


all() ->
    lists:sort(gen_server:call(?MODULE, all, infinity)).


get(Section) when is_binary(Section) ->
    ?MODULE:get(binary_to_list(Section));
get(Section) ->
    Matches = ets:match(?MODULE, {{Section, '$1'}, '$2'}),
    [{Key, Value} || [Key, Value] <- Matches].

get(Section, Key) ->
    ?MODULE:get(Section, Key, undefined).

get(Section, Key, Default) when is_binary(Section) and is_binary(Key) ->
    ?MODULE:get(binary_to_list(Section), binary_to_list(Key), Default);
get(Section, Key, Default) ->
    case ets:lookup(?MODULE, {Section, Key}) of
        [] -> Default;
        [{_, Match}] -> Match
    end.

set(Section, Key, Value) ->
    ?MODULE:set(Section, Key, Value, true).

set(Section, Key, Value, Persist) when is_binary(Section) and is_binary(Key)  ->
    ?MODULE:set(binary_to_list(Section), binary_to_list(Key), Value, Persist);
set(Section, Key, Value, Persist) ->
    gen_server:call(?MODULE, {set, Section, Key, Value, Persist}).


delete(Section, Key) when is_binary(Section) and is_binary(Key) ->
    delete(binary_to_list(Section), binary_to_list(Key));
delete(Section, Key) ->
    delete(Section, Key, true).

delete(Section, Key, Persist) when is_binary(Section) and is_binary(Key) ->
    delete(binary_to_list(Section), binary_to_list(Key), Persist);
delete(Section, Key, Persist) ->
    gen_server:call(?MODULE, {delete, Section, Key, Persist}).


register(Fun) ->
    ?MODULE:register(Fun, self()).

register(Fun, Pid) ->
    couch_config_event:register(Fun, Pid).


init(IniFiles) ->
    ets:new(?MODULE, [named_table, set, protected]),
    lists:map(fun(IniFile) ->
        {ok, ParsedIniValues} = parse_ini_file(IniFile),
        ets:insert(?MODULE, ParsedIniValues)
    end, IniFiles),
    WriteFile = case IniFiles of
        [_|_] -> lists:last(IniFiles);
        _ -> undefined
    end,
    {ok, #config{write_filename=WriteFile}}.


terminate(_Reason, _State) ->
    ok.


handle_call(all, _From, Config) ->
    Resp = lists:sort((ets:tab2list(?MODULE))),
    {reply, Resp, Config};
handle_call({set, Sec, Key, Val, Persist}, _From, Config) ->
    true = ets:insert(?MODULE, {{Sec, Key}, Val}),
    case {Persist, Config#config.write_filename} of
        {true, undefined} ->
            ok;
        {true, FileName} ->
            couch_config_writer:save_to_file({{Sec, Key}, Val}, FileName);
        _ ->
            ok
    end,
    Event = {config_change, Sec, Key, Val, Persist},
    gen_event:sync_notify(couch_config_event, Event),
    {reply, ok, Config};
handle_call({delete, Sec, Key, Persist}, _From, Config) ->
    true = ets:delete(?MODULE, {Sec,Key}),
    case {Persist, Config#config.write_filename} of
        {true, undefined} ->
            ok;
        {true, FileName} ->
            couch_config_writer:save_to_file({{Sec, Key}, ""}, FileName);
        _ ->
            ok
    end,
    Event = {config_change, Sec, Key, deleted, Persist},
    gen_event:sync_notify(couch_config_event, Event),
    {reply, ok, Config}.


handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(Info, State) ->
    twig:log(error, "couch_config:handle_info Info: ~p~n", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


parse_ini_file(IniFile) ->
    IniFilename = couch_util:abs_pathname(IniFile),
    IniBin =
    case file:read_file(IniFilename) of
        {ok, IniBin0} ->
            IniBin0;
        {error, enoent} ->
            Fmt = "Couldn't find server configuration file ~s.",
            Msg = list_to_binary(io_lib:format(Fmt, [IniFilename])),
            twig:log(error, "~s~n", [Msg]),
            throw({startup_error, Msg})
    end,

    Lines = re:split(IniBin, "\r\n|\n|\r|\032", [{return, list}]),
    {_, ParsedIniValues} =
    lists:foldl(fun(Line, {AccSectionName, AccValues}) ->
            case string:strip(Line) of
            "[" ++ Rest ->
                case re:split(Rest, "\\]", [{return, list}]) of
                [NewSectionName, ""] ->
                    {NewSectionName, AccValues};
                _Else -> % end bracket not at end, ignore this line
                    {AccSectionName, AccValues}
                end;
            ";" ++ _Comment ->
                {AccSectionName, AccValues};
            Line2 ->
                case re:split(Line2, "\s?=\s?", [{return, list}]) of
                [Value] ->
                    MultiLineValuePart = case re:run(Line, "^ \\S", []) of
                    {match, _} ->
                        true;
                    _ ->
                        false
                    end,
                    case {MultiLineValuePart, AccValues} of
                    {true, [{{_, ValueName}, PrevValue} | AccValuesRest]} ->
                        % remove comment
                        case re:split(Value, " ;|\t;", [{return, list}]) of
                        [[]] ->
                            % empty line
                            {AccSectionName, AccValues};
                        [LineValue | _Rest] ->
                            E = {{AccSectionName, ValueName},
                                PrevValue ++ " " ++ LineValue},
                            {AccSectionName, [E | AccValuesRest]}
                        end;
                    _ ->
                        {AccSectionName, AccValues}
                    end;
                [""|_LineValues] -> % line begins with "=", ignore
                    {AccSectionName, AccValues};
                [ValueName|LineValues] -> % yeehaw, got a line!
                    RemainingLine = couch_util:implode(LineValues, "="),
                    % removes comments
                    case re:split(RemainingLine, " ;|\t;", [{return, list}]) of
                    [[]] ->
                        % empty line means delete this key
                        ets:delete(?MODULE, {AccSectionName, ValueName}),
                        {AccSectionName, AccValues};
                    [LineValue | _Rest] ->
                        {AccSectionName,
                            [{{AccSectionName, ValueName}, LineValue} | AccValues]}
                    end
                end
            end
        end, {"", []}, Lines),
    {ok, ParsedIniValues}.

