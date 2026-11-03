using TablePro.Interop;

namespace TablePro.App.Services;

internal static class Grammars
{
    public static SqlGrammar For(string engineId) => engineId switch
    {
        "postgres" => SqlGrammar.PostgreSql,
        "mysql" => SqlGrammar.MySql,
        "mssql" => SqlGrammar.MsSql,
        "clickhouse" => SqlGrammar.ClickHouse,
        "duckdb" => SqlGrammar.DuckDb,
        "cassandra" => SqlGrammar.Cql,
        "redis" => SqlGrammar.Redis,
        "mongodb" => SqlGrammar.Mongo,
        _ => SqlGrammar.Sqlite,
    };
}
