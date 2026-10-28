namespace TablePro.Core.Plans;

/// <summary>
/// The shape of the text a server returns for a plan. Keyed by output shape rather than by engine, so engines that
/// print the same thing share one parser.
/// </summary>
public enum PlanFormat
{
    /// <summary>Output no parser reads; shown as text.</summary>
    PlainText,

    /// <summary>PostgreSQL <c>EXPLAIN (FORMAT JSON[, ANALYZE])</c>.</summary>
    PostgresJson,

    /// <summary>MySQL and MariaDB <c>EXPLAIN FORMAT=JSON</c>, or the TREE text <c>EXPLAIN ANALYZE</c> prints.</summary>
    MySql,

    /// <summary>SQLite <c>EXPLAIN QUERY PLAN</c>: id, parent, notused, detail.</summary>
    SqliteQueryPlan,

    /// <summary>CockroachDB's bulleted text tree.</summary>
    CockroachText,

    /// <summary>A tree drawn by indentation, as ClickHouse prints it.</summary>
    IndentedText,

    /// <summary>DM8's plan text, nested by the column its <c>#</c> marker sits in.</summary>
    DamengText,

    /// <summary>A JSON array of PLAN_TABLE rows keyed by column name, null columns left out.</summary>
    OraclePlanRows,

    /// <summary>SQL Server showplan XML, estimated or actual.</summary>
    SqlServerShowplanXml,

    /// <summary>DuckDB <c>EXPLAIN (FORMAT JSON)</c>, or the profile <c>EXPLAIN (ANALYZE, FORMAT JSON)</c> returns.</summary>
    DuckDbJson,
}

/// <summary>
/// The statements that make a server report a machine-readable plan, run in order on one connection, and the format
/// the plan comes back in.
/// </summary>
/// <param name="Statements">What to run. The statement being explained is one of them, so Safe Mode classifies them as they are.</param>
/// <param name="Format">How to read what comes back.</param>
/// <param name="Analyze">Whether the plan executes the statement to measure it.</param>
public sealed record PlanRequest(IReadOnlyList<string> Statements, PlanFormat Format, bool Analyze)
{
    /// <summary>
    /// Whether every statement runs even after one fails. SQL Server's plan switch stays on for the session until it
    /// is turned off, so the statement that turns it off must run whatever happened before it.
    /// </summary>
    public bool RunsEveryStatement { get; init; }
}
