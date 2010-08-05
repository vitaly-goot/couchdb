-module(mem3_util_test).

-include("mem3.hrl").
-include_lib("eunit/include/eunit.hrl").

hash_test() ->
    ?assertEqual(1624516141,mem3_util:hash(0)),
    ?assertEqual(3816901808,mem3_util:hash("0")),
    ?assertEqual(3523407757,mem3_util:hash(<<0>>)),
    ?assertEqual(4108050209,mem3_util:hash(<<"0">>)),
    ?assertEqual(3094724072,mem3_util:hash(zero)),
    ok.

name_shard_test() ->
    Shard1 = #shard{},
    ?assertError(function_clause, mem3_util:name_shard(Shard1)),

    Shard2 = #shard{dbname = <<"testdb">>, range = [0,100]},
    #shard{name=Name2} = mem3_util:name_shard(Shard2),
    ?assertEqual(<<"shards/00000000-00000064/testdb">>, Name2),

    ok.

create_partition_map_test() ->
    {DbName1, N1, Q1, Nodes1} = {<<"testdb1">>, 3, 4, [a,b,c,d]},
    Map1 = mem3_util:create_partition_map(DbName1, N1, Q1, Nodes1),
    ?assertEqual(12, length(Map1)),

    {DbName2, N2, Q2, Nodes2} = {<<"testdb2">>, 1, 1, [a,b,c,d]},
    [#shard{name=Name2,node=Node2}] = Map2 =
        mem3_util:create_partition_map(DbName2, N2, Q2, Nodes2),
    ?assertEqual(1, length(Map2)),
    ?assertEqual(<<"shards/00000000-ffffffff/testdb2">>, Name2),
    ?assertEqual(a, Node2),
    ok.

build_shards_test() ->
    DocProps1 =
         [{<<"changelog">>,
            [[<<"add">>,<<"00000000-1fffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"20000000-3fffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"40000000-5fffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"60000000-7fffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"80000000-9fffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"a0000000-bfffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"c0000000-dfffffff">>,
              <<"dbcore@node.local">>],
             [<<"add">>,<<"e0000000-ffffffff">>,
              <<"dbcore@node.local">>]]},
           {<<"by_node">>,
            {[{<<"dbcore@node.local">>,
               [<<"00000000-1fffffff">>,<<"20000000-3fffffff">>,
                <<"40000000-5fffffff">>,<<"60000000-7fffffff">>,
                <<"80000000-9fffffff">>,<<"a0000000-bfffffff">>,
                <<"c0000000-dfffffff">>,<<"e0000000-ffffffff">>]}]}},
           {<<"by_range">>,
            {[{<<"00000000-1fffffff">>,[<<"dbcore@node.local">>]},
              {<<"20000000-3fffffff">>,[<<"dbcore@node.local">>]},
              {<<"40000000-5fffffff">>,[<<"dbcore@node.local">>]},
              {<<"60000000-7fffffff">>,[<<"dbcore@node.local">>]},
              {<<"80000000-9fffffff">>,[<<"dbcore@node.local">>]},
              {<<"a0000000-bfffffff">>,[<<"dbcore@node.local">>]},
              {<<"c0000000-dfffffff">>,[<<"dbcore@node.local">>]},
              {<<"e0000000-ffffffff">>,[<<"dbcore@node.local">>]}]}}],
    Shards1 = mem3_util:build_shards(<<"testdb1">>, DocProps1),
    ExpectedShards1 =
        [{shard,<<"shards/00000000-1fffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [0,536870911],
          undefined},
         {shard,<<"shards/20000000-3fffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [536870912,1073741823],
          undefined},
         {shard,<<"shards/40000000-5fffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [1073741824,1610612735],
          undefined},
         {shard,<<"shards/60000000-7fffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [1610612736,2147483647],
          undefined},
         {shard,<<"shards/80000000-9fffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [2147483648,2684354559],
          undefined},
         {shard,<<"shards/a0000000-bfffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [2684354560,3221225471],
          undefined},
         {shard,<<"shards/c0000000-dfffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [3221225472,3758096383],
          undefined},
         {shard,<<"shards/e0000000-ffffffff/testdb1">>,
          'dbcore@node.local',<<"testdb1">>,
          [3758096384,4294967295],
          undefined}],
    ?assertEqual(ExpectedShards1, Shards1),
    ok.


%% n_val tests

nval_test() ->
    ?assertEqual(2, mem3_util:n_val(2,4)),
    ?assertEqual(1, mem3_util:n_val(-1,4)),
    ?assertEqual(4, mem3_util:n_val(6,4)),
    ok.

config_01_setup() ->
    Ini = filename:join([code:lib_dir(mem3, test), "01-config-default.ini"]),
    {ok, Pid} = couch_config:start_link([Ini]),
    Pid.

config_teardown(_Pid) ->
    couch_config:stop().

n_val_test_() ->
    {"n_val tests",
     [
      {setup,
       fun config_01_setup/0,
       fun config_teardown/1,
       fun(Pid) ->
           {with, Pid, [
               fun n_val_1/1
            ]}
       end}
     ]
    }.

n_val_1(_Pid) ->
    ?assertEqual(3, mem3_util:n_val(undefined, 4)).
