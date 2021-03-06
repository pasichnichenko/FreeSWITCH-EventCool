-module(boss_db_adapter_mysql).
-behaviour(boss_db_adapter).
-export([start/0, start/1, stop/1, find/2, find/7]).
-export([count/3, counter/2, incr/3, delete/2, save_record/2]).
-export([push/2, pop/2, dump/1, execute/2]).

start() ->
    start([]).

start(Options) ->
    DBHost = proplists:get_value(db_host, Options, "localhost"),
    DBPort = proplists:get_value(db_port, Options, 3306),
    DBUsername = proplists:get_value(db_username, Options, "guest"),
    DBPassword = proplists:get_value(db_password, Options, ""),
    DBDatabase = proplists:get_value(db_database, Options, "test"),
    mysql:start(boss_pool, DBHost, DBPort, DBUsername, DBPassword, DBDatabase),
    {ok, boss_pool}.

stop(_Pid) -> ok.

find(Pid, Id) when is_list(Id) ->
    {Type, TableName, TableId} = infer_type_from_id(Id),
    Res = mysql:fetch(Pid, ["SELECT * FROM ", TableName,
            " WHERE id = ", pack_value(TableId)]),
    case Res of
        {data, MysqlRes} ->
            case mysql:get_result_rows(MysqlRes) of
                [] -> undefined;
                [Row] ->
                    Columns = mysql:get_result_field_info(MysqlRes),
                    case model_is_loaded(Type) of
                        true -> activate_record(Row, Columns, Type);
                        false -> {error, {module_not_loaded, Type}}
                    end
            end;
        {error, MysqlRes} ->
            {error, mysql:get_result_reason(MysqlRes)}
    end.

find(Pid, Type, Conditions, Max, Skip, Sort, SortOrder) when is_atom(Type), is_list(Conditions), 
                                                              is_integer(Max), is_integer(Skip), 
                                                              is_atom(Sort), is_atom(SortOrder) ->
    case model_is_loaded(Type) of
        true ->
            Query = build_select_query(Type, Conditions, Max, Skip, Sort, SortOrder),
            Res = mysql:fetch(Pid, Query),
            case Res of
                {data, MysqlRes} ->
                    Columns = mysql:get_result_field_info(MysqlRes),
                    lists:map(fun(Row) ->
                                activate_record(Row, Columns, Type)
                        end, mysql:get_result_rows(MysqlRes));
                {error, MysqlRes} ->
                    {error, mysql:get_result_reason(MysqlRes)}
            end;
        false -> {error, {module_not_loaded, Type}}
    end.

count(Pid, Type, Conditions) ->
    ConditionClause = build_conditions(Conditions),
    TableName = type_to_table_name(Type),
    Res = mysql:fetch(Pid, ["SELECT COUNT(*) AS count FROM ", TableName, 
            " WHERE ", ConditionClause]),
    case Res of
        {data, MysqlRes} ->
            [[Count]] = mysql:get_result_rows(MysqlRes),
            Count;
        {error, MysqlRes} ->
            {error, mysql:get_result_reason(MysqlRes)}
    end.

counter(Pid, Id) when is_list(Id) ->
    Res = mysql:fetch(Pid, ["SELECT value FROM counters WHERE name = ", pack_value(Id)]),
    case Res of
        {data, MysqlRes} ->
            [[Value]] = mysql:get_result_rows(MysqlRes),
            Value;
        {error, _Reason} -> 0
    end.

incr(Pid, Id, Count) ->
    Res = mysql:fetch(Pid, ["UPDATE counters SET value = value + ", pack_value(Count), 
            " WHERE name = ", pack_value(Id)]),
    case Res of
        {updated, _} ->
            counter(Pid, Id); % race condition
        {error, _Reason} -> 
            Res1 = mysql:fetch(Pid, ["INSERT INTO counters (name, value) VALUES (",
                    pack_value(Id), ", ", pack_value(Count), ")"]),
            case Res1 of
                {updated, _} -> counter(Pid, Id); % race condition
                {error, MysqlRes} -> {error, mysql:get_result_reason(MysqlRes)}
            end
    end.

delete(Pid, Id) when is_list(Id) ->
    {_, TableName, TableId} = infer_type_from_id(Id),
    Res = mysql:fetch(Pid, ["DELETE FROM ", TableName, " WHERE id = ", 
            pack_value(TableId)]),
    case Res of
        {updated, _} ->
            mysql:fetch(Pid, ["DELETE FROM counters WHERE name = ", 
                    pack_value(Id)]),
            ok;
        {error, MysqlRes} -> {error, mysql:get_result_reason(MysqlRes)}
    end.

save_record(Pid, Record) when is_tuple(Record) ->
    case Record:id() of
        id ->
            Type = element(1, Record),
            Query = build_insert_query(Record),
            Res = mysql:fetch(Pid, Query),
            case Res of
                {updated, _} ->
                    Res1 = mysql:fetch(Pid, "SELECT last_insert_id()"),
                    case Res1 of
                        {data, MysqlRes} ->
                            [[Id]] = mysql:get_result_rows(MysqlRes),
                            {ok, Record:id(lists:concat([Type, "-", integer_to_list(Id)]))};
                        {error, MysqlRes} ->
                            {error, mysql:get_result_reason(MysqlRes)}
                    end;
                {error, MysqlRes} -> {error, mysql:get_result_reason(MysqlRes)}
            end;
		Identifier when is_integer(Identifier) ->
            Type = element(1, Record),
            Query = build_insert_query(Record),
            Res = mysql:fetch(Pid, Query),
            case Res of
                {updated, _} ->
					{ok, Record:id(lists:concat([Type, "-", integer_to_list(Identifier)]))};
                {error, MysqlRes} -> {error, mysql:get_result_reason(MysqlRes)}
            end;			
        Defined when is_list(Defined) ->
            Query = build_update_query(Record),
            Res = mysql:fetch(Pid, Query),
            case Res of
                {updated, _} -> {ok, Record};
                {error, MysqlRes} -> {error, mysql:get_result_reason(MysqlRes)}
            end
    end.

push(Pid, Depth) ->
    case Depth of 0 -> mysql:fetch(Pid, "BEGIN"); _ -> ok end,
    mysql:fetch(Pid, ["SAVEPOINT savepoint", integer_to_list(Depth)]).

pop(Pid, Depth) ->
    mysql:fetch(Pid, ["ROLLBACK TO SAVEPOINT savepoint", integer_to_list(Depth - 1)]),
    mysql:fetch(Pid, ["RELEASE SAVEPOINT savepoint", integer_to_list(Depth - 1)]).

dump(_Conn) -> "".

execute(Pid, Commands) ->
    mysql:fetch(Pid, Commands).

% internal

infer_type_from_id(Id) when is_list(Id) ->
    [Type, TableId] = string:tokens(Id, "-"),
    {list_to_atom(Type), type_to_table_name(Type), list_to_integer(TableId)}.

type_to_table_name(Type) when is_atom(Type) ->
    type_to_table_name(atom_to_list(Type));
type_to_table_name(Type) when is_list(Type) ->
    inflector:pluralize(Type).

activate_record(Record, Metadata, Type) ->
    DummyRecord = apply(Type, new, lists:seq(1, proplists:get_value(new, Type:module_info(exports)))),
    apply(Type, new, lists:map(fun
                (id) ->
                    Index = keyindex(<<"id">>, 2, Metadata),
                    atom_to_list(Type) ++ "-" ++ integer_to_list(lists:nth(Index, Record));
                (Key) ->
                    Index = keyindex(list_to_binary(atom_to_list(Key)), 2, Metadata),
                    case lists:nth(Index, Record) of
                        {datetime, DateTime} -> DateTime;
                        Val -> Val
                    end
            end, DummyRecord:attribute_names())).

model_is_loaded(Type) ->
    case code:is_loaded(Type) of
        {file, _Loaded} ->
            Exports = Type:module_info(exports),
            case proplists:get_value(attribute_names, Exports) of
                1 -> true;
                _ -> false
            end;
        false -> false
    end.

keyindex(Key, N, TupleList) ->
    keyindex(Key, N, TupleList, 1).

keyindex(_Key, _N, [], _Index) ->
    undefined;
keyindex(Key, N, [Tuple|Rest], Index) ->
    case element(N, Tuple) of
        Key -> Index;
        _ -> keyindex(Key, N, Rest, Index + 1)
    end.

sort_order_sql(num_ascending) ->
    "ASC";
sort_order_sql(num_descending) ->
    "DESC";
sort_order_sql(str_ascending) ->
    "ASC";
sort_order_sql(str_descending) ->
    "DESC".

build_insert_query(Record) ->
    Type = element(1, Record),
    TableName = type_to_table_name(Type),
    {Attributes, Values} = lists:foldl(fun
			({id, V}, {Attrs, Vals}) when is_integer(V) -> {[atom_to_list(id)|Attrs], [pack_value(V)|Vals]};
			({id, _}, Acc) -> Acc;
            ({_, undefined}, Acc) -> Acc;
            ({A, V}, {Attrs, Vals}) ->
                {[atom_to_list(A)|Attrs], [pack_value(V)|Vals]}
        end, {[], []}, Record:attributes()),
    ["INSERT INTO ", TableName, " (", 
        string:join(Attributes, ", "),
        ") values (",
        string:join(Values, ", "),
        ")"
    ].

build_update_query(Record) ->
    {_, TableName, Id} = infer_type_from_id(Record:id()),
    Updates = lists:foldl(fun
            ({id, _}, Acc) -> Acc;
            ({A, V}, Acc) -> [atom_to_list(A) ++ " = " ++ pack_value(V)|Acc]
        end, [], Record:attributes()),
    ["UPDATE ", TableName, " SET ", string:join(Updates, ", "),
        " WHERE id = ", pack_value(Id)].

build_select_query(Type, Conditions, Max, Skip, Sort, SortOrder) ->
    TableName = type_to_table_name(Type),
    ["SELECT * FROM ", TableName, 
        " WHERE ", build_conditions(Conditions),
        " ORDER BY ", atom_to_list(Sort), " ", sort_order_sql(SortOrder),
        " LIMIT ", integer_to_list(Max), 
        " OFFSET ", integer_to_list(Skip)
    ].

build_conditions(Conditions) ->
    build_conditions1(Conditions, [" TRUE"]).

build_conditions1([], Acc) ->
    Acc;
build_conditions1([{Key, 'equals', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "=", pack_value(Value)));
build_conditions1([{Key, 'not_equals', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "!=", pack_value(Value)));
build_conditions1([{Key, 'in', Value}|Rest], Acc) when is_list(Value) ->
    PackedValues = pack_set(Value),
    build_conditions1(Rest, add_cond(Acc, Key, "IN", PackedValues));
build_conditions1([{Key, 'not_in', Value}|Rest], Acc) when is_list(Value) ->
    PackedValues = pack_set(Value),
    build_conditions1(Rest, add_cond(Acc, Key, "NOT IN", PackedValues));
build_conditions1([{Key, 'in', {Min, Max}}|Rest], Acc) when Max >= Min ->
    PackedValues = pack_range(Min, Max),
    build_conditions1(Rest, add_cond(Acc, Key, "BETWEEN", PackedValues));
build_conditions1([{Key, 'not_in', {Min, Max}}|Rest], Acc) when Max >= Min ->
    PackedValues = pack_range(Min, Max),
    build_conditions1(Rest, add_cond(Acc, Key, "NOT BETWEEN", PackedValues));
build_conditions1([{Key, 'gt', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, ">", pack_value(Value)));
build_conditions1([{Key, 'lt', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "<", pack_value(Value)));
build_conditions1([{Key, 'ge', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, ">=", pack_value(Value)));
build_conditions1([{Key, 'le', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "<=", pack_value(Value)));
build_conditions1([{Key, 'matches', "*"++Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "REGEXP", pack_value(Value)));
build_conditions1([{Key, 'not_matches', "*"++Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "NOT REGEXP", pack_value(Value)));
build_conditions1([{Key, 'matches', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "REGEXP BINARY", pack_value(Value)));
build_conditions1([{Key, 'not_matches', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, "NOT REGEXP BINARY", pack_value(Value)));
build_conditions1([{Key, 'contains', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, pack_match(Key), "AGAINST", pack_boolean_query([Value], "")));
build_conditions1([{Key, 'not_contains', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, pack_match_not(Key), "AGAINST", pack_boolean_query([Value], "")));
build_conditions1([{Key, 'contains_all', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_match(Key), "AGAINST", pack_boolean_query(Values, "+")));
build_conditions1([{Key, 'not_contains_all', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_match_not(Key), "AGAINST", pack_boolean_query(Values, "+")));
build_conditions1([{Key, 'contains_any', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_match(Key), "AGAINST", pack_boolean_query(Values, "")));
build_conditions1([{Key, 'contains_none', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, pack_match_not(Key), "AGAINST", pack_boolean_query(Values, ""))).

add_cond(Acc, Key, Op, PackedVal) ->
    [lists:concat([Key, " ", Op, " ", PackedVal, " AND "])|Acc].

pack_match(Key) ->
    lists:concat(["MATCH(", Key, ")"]).

pack_match_not(Key) ->
    lists:concat(["NOT MATCH(", Key, ")"]).

pack_boolean_query(Values, Op) ->
    "('" ++ string:join(lists:map(fun(Val) -> Op ++ escape_sql(Val) end, Values), " ") ++ "' IN BOOLEAN MODE)".

pack_set(Values) ->
    "(" ++ string:join(lists:map(fun pack_value/1, Values), ", ") ++ ")".

pack_range(Min, Max) ->
    pack_value(Min) ++ " AND " ++ pack_value(Max).

escape_sql(Value) ->
    escape_sql1(Value, []).

escape_sql1([], Acc) ->
    lists:reverse(Acc);
escape_sql1([$'|Rest], Acc) ->
    escape_sql1(Rest, [$', $'|Acc]);
escape_sql1([C|Rest], Acc) ->
    escape_sql1(Rest, [C|Acc]).

pack_datetime(DateTime) ->
    "'" ++ erlydtl_filters:date(DateTime, "Y-m-d H:i:s") ++ "'".

pack_now(Now) -> pack_datetime(calendar:now_to_datetime(Now)).

pack_value(undefined) ->
	"''";
pack_value(V) when is_binary(V) ->
    pack_value(binary_to_list(V));
pack_value(V) when is_list(V) ->
    "'" ++ escape_sql(V) ++ "'";
pack_value({MegaSec, Sec, MicroSec}) when is_integer(MegaSec) andalso is_integer(Sec) andalso is_integer(MicroSec) ->
    pack_now({MegaSec, Sec, MicroSec});
pack_value({{_, _, _}, {_, _, _}} = Val) ->
    pack_datetime(Val);
pack_value(Val) when is_integer(Val) ->
    integer_to_list(Val);
pack_value(Val) when is_float(Val) ->
    float_to_list(Val);
pack_value(true) ->
    "TRUE";
pack_value(false) ->
    "FALSE".
