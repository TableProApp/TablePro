namespace TablePro.Core.Tests.Plans;

/// <summary>
/// Plan text as servers returned it. The PostgreSQL, MySQL, SQL Server, Oracle and CockroachDB samples are the macOS
/// app's test fixtures (PostgreSQL 17, SQL Server 2022 16.0.4135 trimmed to the elements the parser reads); the
/// SQLite and DuckDB samples were captured from Microsoft.Data.Sqlite 10.0.14 and DuckDB 1.5 through DuckDB.NET, and
/// are flattened the way <c>PlanText.Flatten</c> joins columns and rows. The DuckDB profile drops the profiler's
/// zero-valued storage counters, which the parser does not read.
/// </summary>
internal static class PlanFixtures
{
    public const string PostgresEstimated = """
        [
          {
            "Plan": {
              "Node Type": "Hash Join",
              "Join Type": "Inner",
              "Startup Cost": 1.09,
              "Total Cost": 40.35,
              "Plan Rows": 220,
              "Plan Width": 68,
              "Plans": [
                {
                  "Node Type": "Seq Scan",
                  "Relation Name": "orders",
                  "Schema": "public",
                  "Alias": "o",
                  "Startup Cost": 0.00,
                  "Total Cost": 30.20,
                  "Plan Rows": 200,
                  "Plan Width": 36,
                  "Filter": "(status = 'paid'::text)"
                },
                {
                  "Node Type": "Hash",
                  "Startup Cost": 1.04,
                  "Total Cost": 1.04,
                  "Plan Rows": 4,
                  "Plan Width": 32
                }
              ]
            }
          }
        ]
        """;

    public const string PostgresAnalyze = """
        [
          {
            "Plan": {
              "Node Type": "Seq Scan",
              "Relation Name": "users",
              "Startup Cost": 0.00,
              "Total Cost": 12.50,
              "Plan Rows": 250,
              "Plan Width": 40,
              "Actual Startup Time": 0.015,
              "Actual Total Time": 0.132,
              "Actual Rows": 250,
              "Actual Loops": 1
            },
            "Planning Time": 0.183,
            "Execution Time": 0.201
          }
        ]
        """;

    /// <summary>
    /// <c>EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM outerT o JOIN innerT i ON i.id = o.id</c> on PostgreSQL 17.11
    /// with hash and merge joins disabled, so the inner side runs once per outer row.
    /// </summary>
    public const string PostgresNestedLoop = """
        [
          {
            "Plan": {
              "Node Type": "Nested Loop",
              "Join Type": "Inner",
              "Startup Cost": 0.29, "Total Cost": 1162.50,
              "Plan Rows": 500, "Plan Width": 29,
              "Actual Startup Time": 0.011, "Actual Total Time": 0.233,
              "Actual Rows": 500, "Actual Loops": 1,
              "Plans": [
                {
                  "Node Type": "Seq Scan", "Relation Name": "outert", "Alias": "o",
                  "Startup Cost": 0.00, "Total Cost": 9.00,
                  "Plan Rows": 500, "Plan Width": 4,
                  "Actual Startup Time": 0.004, "Actual Total Time": 0.016,
                  "Actual Rows": 500, "Actual Loops": 1
                },
                {
                  "Node Type": "Index Scan", "Relation Name": "innert", "Alias": "i",
                  "Startup Cost": 0.29, "Total Cost": 2.30,
                  "Plan Rows": 1, "Plan Width": 25,
                  "Actual Startup Time": 0.0002, "Actual Total Time": 0.0004,
                  "Actual Rows": 1, "Actual Loops": 500
                }
              ]
            },
            "Planning Time": 0.235,
            "Execution Time": 0.259
          }
        ]
        """;

    /// <summary>The same server with <c>max_parallel_workers_per_gather = 2</c>.</summary>
    public const string PostgresParallel = """
        [
          {
            "Plan": {
              "Node Type": "Aggregate",
              "Startup Cost": 28194.98, "Total Cost": 28194.99,
              "Plan Rows": 1, "Plan Width": 8,
              "Actual Total Time": 120.701, "Actual Rows": 1, "Actual Loops": 1,
              "Plans": [
                {
                  "Node Type": "Gather",
                  "Startup Cost": 28194.97, "Total Cost": 28194.98,
                  "Plan Rows": 2, "Plan Width": 8,
                  "Actual Total Time": 120.697, "Actual Rows": 3, "Actual Loops": 1,
                  "Workers Planned": 2, "Workers Launched": 2,
                  "Plans": [
                    {
                      "Node Type": "Aggregate",
                      "Startup Cost": 28194.97, "Total Cost": 28194.97,
                      "Plan Rows": 1, "Plan Width": 8,
                      "Actual Total Time": 117.691, "Actual Rows": 1, "Actual Loops": 3,
                      "Plans": [
                        {
                          "Node Type": "Seq Scan", "Relation Name": "big",
                          "Startup Cost": 0.00, "Total Cost": 27753.00,
                          "Plan Rows": 76323, "Plan Width": 0,
                          "Actual Total Time": 116.215, "Actual Rows": 76323, "Actual Loops": 3
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            "Execution Time": 120.728
          }
        ]
        """;

    public const string MySqlTreeAnalyze = """
        -> Inner hash join (t2.c2 = t1.c1)  (cost=3.5 rows=5) (actual time=0.121..0.131 rows=1 loops=1)
            -> Table scan on t2  (cost=0.07 rows=5) (actual time=0.0126..0.0221 rows=5 loops=1)
            -> Hash
                -> Table scan on t1  (cost=0.75 rows=5) (actual time=0.0372..0.0534 rows=5 loops=1)
        """;

    public const string MySqlJson = """
        {
          "query_block": {
            "select_id": 1,
            "cost_info": { "query_cost": "3.50" },
            "table": {
              "table_name": "orders",
              "access_type": "ALL",
              "rows_examined_per_scan": 10,
              "cost_info": {
                "read_cost": "2.25",
                "eval_cost": "1.25",
                "prefix_cost": "3.50",
                "data_read_per_join": "1K"
              }
            }
          }
        }
        """;

    private const string ShowplanNamespace = """xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4135.4" """;

    public const string SqlServerActual = "<ShowPlanXML " + ShowplanNamespace + """
        ><BatchSequence><Batch><Statements>
        <StmtSimple StatementText="SELECT c.name FROM customers c JOIN orders o ON o.customer_id = c.id" StatementType="SELECT" StatementSubTreeCost="0.104866">
        <QueryPlan DegreeOfParallelism="1" CompileTime="249">
        <Warnings><PlanAffectingConvert ConvertIssue="Seek Plan" Expression="CONVERT_IMPLICIT(nvarchar(50),[c].[city],0)=N'city7'"/></Warnings>
        <QueryTimeStats ElapsedTime="114" CpuTime="114"/>
        <RelOp NodeId="0" PhysicalOp="Hash Match" LogicalOp="Inner Join" EstimateRows="213.12" EstimateIO="0" EstimateCPU="0.0405522" AvgRowSize="132" EstimatedTotalSubtreeCost="0.104866" Parallel="0" EstimateRebinds="0" EstimateRewinds="0" EstimatedExecutionMode="Row">
        <RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="14" ActualElapsedms="33" ActualEndOfScans="1" ActualExecutions="1"/></RunTimeInformation>
        <Hash><DefinedValues/>
        <RelOp NodeId="1" PhysicalOp="Clustered Index Scan" LogicalOp="Clustered Index Scan" EstimateRows="80" AvgRowSize="122" EstimatedTotalSubtreeCost="0.0114079" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">
        <Warnings NoJoinPredicate="1"/>
        <RunTimeInformation>
        <RunTimeCountersPerThread Thread="1" ActualRows="30" ActualElapsedms="2" ActualLogicalReads="5" ActualExecutions="2"/>
        <RunTimeCountersPerThread Thread="2" ActualRows="10" ActualElapsedms="3" ActualLogicalReads="6" ActualExecutions="2"/>
        </RunTimeInformation>
        <IndexScan Ordered="0"><DefinedValues/>
        <Object Database="[probe]" Schema="[dbo]" Table="[customers]" Index="[PK__customer]" Alias="[c]" IndexKind="Clustered"/>
        <Predicate><ScalarOperator ScalarString="[probe].[dbo].[customers].[city] as [c].[city]='city7'"><Const ConstValue="'city7'"/></ScalarOperator></Predicate>
        </IndexScan></RelOp>
        <RelOp NodeId="2" PhysicalOp="Sort" LogicalOp="Sort" EstimateRows="40" AvgRowSize="20" EstimatedTotalSubtreeCost="0.05" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">
        <Warnings><SpillToTempDb SpillLevel="1" SpilledThreadCount="1"/></Warnings>
        <RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="0" ActualExecutions="0"/></RunTimeInformation>
        <Sort Distinct="0"><RelOp NodeId="3" PhysicalOp="Table Scan" LogicalOp="Table Scan" EstimateRows="40" AvgRowSize="20" EstimatedTotalSubtreeCost="0.01" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">
        <TableScan><Object Database="[probe]" Schema="[dbo]" Table="[orders]" Alias="[o]"/></TableScan></RelOp></Sort>
        </RelOp>
        </Hash></RelOp>
        </QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>
        """;

    public const string SqlServerMissingIndex = "<ShowPlanXML " + ShowplanNamespace + """
        ><BatchSequence><Batch><Statements>
        <StmtSimple StatementText="SELECT id FROM orders WHERE status = 'open' AND total &gt; 10" StatementType="SELECT">
        <QueryPlan CompileTime="2">
        <MissingIndexes><MissingIndexGroup Impact="93.5"><MissingIndex Database="[probe]" Schema="[dbo]" Table="[orders]">
        <ColumnGroup Usage="EQUALITY"><Column Name="[status]" ColumnId="4"/></ColumnGroup>
        <ColumnGroup Usage="INEQUALITY"><Column Name="[total]" ColumnId="3"/></ColumnGroup>
        <ColumnGroup Usage="INCLUDE"><Column Name="[id]" ColumnId="1"/></ColumnGroup>
        </MissingIndex></MissingIndexGroup></MissingIndexes>
        <RelOp NodeId="0" PhysicalOp="Clustered Index Scan" LogicalOp="Clustered Index Scan" EstimateRows="12" AvgRowSize="11" EstimatedTotalSubtreeCost="0.0114" Parallel="0" EstimateRebinds="0" EstimateRewinds="0">
        <IndexScan><Object Database="[probe]" Schema="[dbo]" Table="[orders]" Index="[PK_orders]"/></IndexScan></RelOp>
        </QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>
        """;

    public const string OracleEstimated = """
        [
        {"ID":0,"OPERATION":"SELECT STATEMENT","COST":7,"CARDINALITY":3,"BYTES":153},
        {"ID":1,"PARENT_ID":0,"OPERATION":"HASH JOIN","COST":7,"CARDINALITY":3,"ACCESS_PREDICATES":"\"O\".\"CUSTOMER_ID\"=\"C\".\"ID\""},
        {"ID":2,"PARENT_ID":1,"OPERATION":"TABLE ACCESS","OPTIONS":"BY INDEX ROWID BATCHED","OBJECT_OWNER":"APP","OBJECT_NAME":"CUSTOMERS","OBJECT_TYPE":"TABLE","OBJECT_ALIAS":"C@SEL$1","COST":2,"CARDINALITY":1},
        {"ID":3,"PARENT_ID":2,"OPERATION":"INDEX","OPTIONS":"RANGE SCAN","OBJECT_OWNER":"APP","OBJECT_NAME":"CUSTOMERS_CITY_IX","OBJECT_TYPE":"INDEX","COST":1,"CARDINALITY":1,"ACCESS_PREDICATES":"\"C\".\"CITY\"='Hanoi'"},
        {"ID":4,"PARENT_ID":1,"OPERATION":"TABLE ACCESS","OPTIONS":"FULL","OBJECT_OWNER":"APP","OBJECT_NAME":"ORDERS","OBJECT_TYPE":"TABLE","COST":5,"CARDINALITY":40,"FILTER_PREDICATES":"\"O\".\"STATUS\"='open'"}
        ]
        """;

    public const string OracleActual = """
        [
        {"ID":0,"OPERATION":"SELECT STATEMENT"},
        {"ID":1,"PARENT_ID":0,"OPERATION":"NESTED LOOPS","LAST_STARTS":1,"LAST_OUTPUT_ROWS":12,"LAST_ELAPSED_TIME":4000},
        {"ID":2,"PARENT_ID":1,"OPERATION":"INDEX","OPTIONS":"UNIQUE SCAN","OBJECT_NAME":"PK","OBJECT_TYPE":"INDEX (UNIQUE)","LAST_STARTS":4,"LAST_OUTPUT_ROWS":12,"LAST_ELAPSED_TIME":2000,"LAST_CR_BUFFER_GETS":8},
        {"ID":3,"PARENT_ID":1,"OPERATION":"TABLE ACCESS","OPTIONS":"FULL","OBJECT_NAME":"T","LAST_STARTS":0,"LAST_OUTPUT_ROWS":0}
        ]
        """;

    public const string Cockroach = """
        distribution: local
        vectorized: true

        • sort
        │ estimated row count: 333
        │ order: +name
        │
        └── • filter
            │ estimated row count: 333
            │ filter: age > 18
            │
            └── • scan
                  estimated row count: 1,000 (100% of the table)
                  table: users@users_pkey
                  spans: FULL SCAN
        """;

    /// <summary>
    /// <c>EXPLAIN QUERY PLAN SELECT c.name, count(*) FROM customers c JOIN orders o ON o.customer_id = c.id WHERE
    /// o.status = 'open' AND c.id IN (SELECT customer_id FROM orders WHERE total &gt; 100) GROUP BY c.name ORDER BY 2 DESC</c>.
    /// </summary>
    public const string SqliteJoin = "9\t0\t91\tSEARCH c USING INTEGER PRIMARY KEY (rowid=?)\n"
        + "13\t0\t0\tLIST SUBQUERY 1\n"
        + "15\t13\t216\tSCAN orders\n"
        + "30\t0\t61\tSEARCH o USING INDEX idx_orders_customer (customer_id=?)\n"
        + "37\t0\t0\tUSE TEMP B-TREE FOR GROUP BY\n"
        + "73\t0\t0\tUSE TEMP B-TREE FOR ORDER BY";

    /// <summary><c>EXPLAIN QUERY PLAN SELECT * FROM orders WHERE customer_id = 3 UNION ALL SELECT * FROM orders WHERE status = 'paid'</c>.</summary>
    public const string SqliteUnion = "1\t0\t0\tCOMPOUND QUERY\n"
        + "2\t1\t0\tLEFT-MOST SUBQUERY\n"
        + "5\t2\t61\tSEARCH orders USING INDEX idx_orders_customer (customer_id=?)\n"
        + "18\t1\t0\tUNION ALL\n"
        + "20\t18\t216\tSCAN orders";

    /// <summary>
    /// <c>EXPLAIN (FORMAT JSON) SELECT c.city, count(*), sum(o.total) FROM customers c JOIN orders o ON o.customer_id =
    /// c.id WHERE o.total &gt; 100 GROUP BY c.city ORDER BY 2 DESC</c>, with the key column DuckDB returns beside it.
    /// </summary>
    public const string DuckDbExplain = "physical_plan\t" + """
        [
            {
                "name": "PROJECTION",
                "children": [
                    {
                        "name": "ORDER_BY",
                        "children": [
                            {
                                "name": "PROJECTION",
                                "children": [
                                    {
                                        "name": "PROJECTION",
                                        "children": [
                                            {
                                                "name": "PERFECT_HASH_GROUP_BY",
                                                "children": [
                                                    {
                                                        "name": "PROJECTION",
                                                        "children": [
                                                            {
                                                                "name": "PROJECTION",
                                                                "children": [
                                                                    {
                                                                        "name": "HASH_JOIN",
                                                                        "children": [
                                                                            {
                                                                                "name": "SEQ_SCAN",
                                                                                "children": [],
                                                                                "extra_info": {
                                                                                    "Table": "memory.main.orders",
                                                                                    "Type": "Sequential Scan",
                                                                                    "Projections": [
                                                                                        "customer_id",
                                                                                        "total"
                                                                                    ],
                                                                                    "Filters": "total>100.0",
                                                                                    "Estimated Cardinality": "4000"
                                                                                }
                                                                            },
                                                                            {
                                                                                "name": "SEQ_SCAN",
                                                                                "children": [],
                                                                                "extra_info": {
                                                                                    "Table": "memory.main.customers",
                                                                                    "Type": "Sequential Scan",
                                                                                    "Projections": [
                                                                                        "id",
                                                                                        "city"
                                                                                    ],
                                                                                    "Estimated Cardinality": "1000"
                                                                                }
                                                                            }
                                                                        ],
                                                                        "extra_info": {
                                                                            "Join Type": "INNER",
                                                                            "Conditions": "customer_id = id",
                                                                            "Estimated Cardinality": "2930"
                                                                        }
                                                                    }
                                                                ],
                                                                "extra_info": {
                                                                    "Projections": [
                                                                        "#0",
                                                                        "__internal_compress_integral_utinyint(#1, 0)"
                                                                    ],
                                                                    "Estimated Cardinality": "2930"
                                                                }
                                                            }
                                                        ],
                                                        "extra_info": {
                                                            "Projections": [
                                                                "city",
                                                                "total"
                                                            ],
                                                            "Estimated Cardinality": "2930"
                                                        }
                                                    }
                                                ],
                                                "extra_info": {
                                                    "Groups": "#0",
                                                    "Aggregates": [
                                                        "count_star()",
                                                        "sum(#1)"
                                                    ]
                                                }
                                            }
                                        ],
                                        "extra_info": {
                                            "Projections": [
                                                "__internal_decompress_integral_bigint(#0, 0)",
                                                "#1",
                                                "#2"
                                            ],
                                            "Estimated Cardinality": "11"
                                        }
                                    }
                                ],
                                "extra_info": {
                                    "Projections": [
                                        "__internal_compress_integral_utinyint(#0, 0)",
                                        "#1",
                                        "#2"
                                    ],
                                    "Estimated Cardinality": "11"
                                }
                            }
                        ],
                        "extra_info": {
                            "Order By": "count_star() DESC"
                        }
                    }
                ],
                "extra_info": {
                    "Projections": [
                        "__internal_decompress_integral_bigint(#0, 0)",
                        "#1",
                        "#2"
                    ],
                    "Estimated Cardinality": "0"
                }
            }
        ]
        """;

    /// <summary><c>EXPLAIN (ANALYZE, FORMAT JSON) SELECT customer_id, count(*) FROM orders WHERE total &gt; 100 GROUP BY customer_id</c>.</summary>
    public const string DuckDbAnalyze = "analyzed_plan\t" + """
        {
            "cumulative_cardinality": 61799,
            "cumulative_rows_scanned": 20000,
            "cpu_time": 0.0010878,
            "extra_info": {},
            "latency": 0.0017683,
            "query_name": "EXPLAIN (ANALYZE, FORMAT JSON) SELECT customer_id, count(*) FROM orders WHERE total > 100 GROUP BY customer_id",
            "result_set_size": 0,
            "rows_returned": 0,
            "system_peak_buffer_memory": 8290304,
            "children": [
                {
                    "cumulative_cardinality": 61799,
                    "extra_info": {},
                    "operator_cardinality": 0,
                    "operator_name": "EXPLAIN_ANALYZE",
                    "operator_rows_scanned": 0,
                    "operator_timing": 1e-7,
                    "operator_type": "EXPLAIN_ANALYZE",
                    "children": [
                        {
                            "cumulative_cardinality": 61799,
                            "extra_info": {
                                "Projections": [
                                    "__internal_decompress_integral_bigint(#0, 0)",
                                    "#1"
                                ],
                                "Estimated Cardinality": "1292"
                            },
                            "operator_cardinality": 1000,
                            "operator_name": "PROJECTION",
                            "operator_rows_scanned": 0,
                            "operator_timing": 0.0005124,
                            "operator_type": "PROJECTION",
                            "children": [
                                {
                                    "cumulative_cardinality": 60799,
                                    "extra_info": {
                                        "Groups": "#0",
                                        "Aggregates": "count_star()"
                                    },
                                    "operator_cardinality": 1000,
                                    "operator_name": "PERFECT_HASH_GROUP_BY",
                                    "operator_rows_scanned": 0,
                                    "operator_timing": 0.000066,
                                    "operator_type": "PERFECT_HASH_GROUP_BY",
                                    "children": [
                                        {
                                            "cumulative_cardinality": 59799,
                                            "extra_info": {
                                                "Projections": "customer_id",
                                                "Estimated Cardinality": "4000"
                                            },
                                            "operator_cardinality": 19933,
                                            "operator_name": "PROJECTION",
                                            "operator_rows_scanned": 0,
                                            "operator_timing": 0.000002,
                                            "operator_type": "PROJECTION",
                                            "children": [
                                                {
                                                    "cumulative_cardinality": 39866,
                                                    "extra_info": {
                                                        "Projections": "__internal_compress_integral_usmallint(#0, 0)",
                                                        "Estimated Cardinality": "4000"
                                                    },
                                                    "operator_cardinality": 19933,
                                                    "operator_name": "PROJECTION",
                                                    "operator_rows_scanned": 0,
                                                    "operator_timing": 0.00034510000000000004,
                                                    "operator_type": "PROJECTION",
                                                    "children": [
                                                        {
                                                            "cumulative_cardinality": 19933,
                                                            "extra_info": {
                                                                "Table": "memory.main.orders",
                                                                "Type": "Sequential Scan",
                                                                "Projections": "customer_id",
                                                                "Filters": "total>100.0",
                                                                "Estimated Cardinality": "4000"
                                                            },
                                                            "operator_cardinality": 19933,
                                                            "operator_name": "SEQ_SCAN",
                                                            "operator_rows_scanned": 20000,
                                                            "operator_timing": 0.0001622,
                                                            "operator_type": "TABLE_SCAN",
                                                            "children": []
                                                        }
                                                    ]
                                                }
                                            ]
                                        }
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """;
}
