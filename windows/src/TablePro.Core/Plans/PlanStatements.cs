namespace TablePro.Core.Plans;

/// <summary>
/// The plan statements each engine family understands, kept beside the parsers that read their output so a format and
/// the SQL that asks for it change together. The dialects return these from <c>SqlDialect.PlanStatements</c>.
/// </summary>
public static class PlanStatements
{
    /// <summary>Names the rows <c>EXPLAIN PLAN</c> writes, so reading them back never picks up another statement's plan.</summary>
    public const string OracleStatementId = "TABLEPRO_PLAN";

    private const string Marker = "\u0001";

    /// <summary>
    /// The plan request a hand-typed statement spells, when it spells one of the dialect's own single-statement forms, so
    /// typing <c>EXPLAIN (FORMAT JSON) ...</c> draws the same plan as the Explain action. Case and spacing are ignored.
    /// </summary>
    public static PlanRequest? Recognize(Sql.SqlDialect dialect, string statement)
    {
        ArgumentNullException.ThrowIfNull(dialect);
        ArgumentNullException.ThrowIfNull(statement);
        var typed = Squeeze(statement);
        foreach (var analyze in (ReadOnlySpan<bool>)[true, false])
        {
            if (dialect.PlanStatements(Marker, analyze) is { Statements: [var only] } request && only.IndexOf(Marker, StringComparison.Ordinal) is var at and > 0)
            {
                var prefix = Squeeze(only[..at]);
                if (typed.StartsWith(prefix, StringComparison.Ordinal) && typed.Length > prefix.Length)
                {
                    return request with { Statements = [statement] };
                }
            }
        }

        return null;
    }

    private static string Squeeze(string text)
    {
        var squeezed = new System.Text.StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (!char.IsWhiteSpace(c))
            {
                squeezed.Append(char.ToUpperInvariant(c));
            }
        }

        return squeezed.ToString();
    }

    public static PlanRequest PostgreSql(string statement, bool analyze) =>
        new([(analyze ? "EXPLAIN (ANALYZE, FORMAT JSON) " : "EXPLAIN (FORMAT JSON) ") + statement], PlanFormat.PostgresJson, analyze);

    /// <summary>
    /// JSON for an estimate. ANALYZE has no JSON form on MySQL, which prints its measured plan only as the TREE text;
    /// the parser reads both.
    /// </summary>
    public static PlanRequest MySql(string statement, bool analyze) =>
        new([(analyze ? "EXPLAIN ANALYZE " : "EXPLAIN FORMAT=JSON ") + statement], PlanFormat.MySql, analyze);

    /// <summary>
    /// MariaDB has no EXPLAIN ANALYZE; its ANALYZE statement runs the query and prints the JSON plan with measured
    /// <c>r_</c> figures beside the estimates, which the same parser reads.
    /// </summary>
    public static PlanRequest MariaDb(string statement, bool analyze) =>
        new([(analyze ? "ANALYZE FORMAT=JSON " : "EXPLAIN FORMAT=JSON ") + statement], PlanFormat.MySql, analyze);

    /// <summary>
    /// SHOWPLAN and STATISTICS XML must each be alone in their batch and stay on for the session until switched off,
    /// so the switch-off runs even when the statement fails.
    /// </summary>
    public static PlanRequest SqlServer(string statement, bool analyze)
    {
        var option = analyze ? "STATISTICS XML" : "SHOWPLAN_XML";
        return new PlanRequest([$"SET {option} ON", statement, $"SET {option} OFF"], PlanFormat.SqlServerShowplanXml, analyze) { RunsEveryStatement = true };
    }

    /// <summary>SQLite has no measured plan; <c>EXPLAIN QUERY PLAN</c> is all it offers.</summary>
    public static PlanRequest? Sqlite(string statement, bool analyze) =>
        analyze ? null : new(["EXPLAIN QUERY PLAN " + statement], PlanFormat.SqliteQueryPlan, false);

    public static PlanRequest DuckDb(string statement, bool analyze) =>
        new([(analyze ? "EXPLAIN (ANALYZE, FORMAT JSON) " : "EXPLAIN (FORMAT JSON) ") + statement], PlanFormat.DuckDbJson, analyze);

    /// <summary>ClickHouse's EXPLAIN draws its plan by indentation; its measured form is a different report.</summary>
    public static PlanRequest? ClickHouse(string statement, bool analyze) =>
        analyze ? null : new(["EXPLAIN " + statement], PlanFormat.IndentedText, false);

    /// <summary>
    /// Writes the plan to PLAN_TABLE under a known statement id and reads the newest plan back as rows. A measured plan
    /// needs V$SQL_PLAN_STATISTICS_ALL and the privilege to read it, so it is not offered here.
    /// </summary>
    public static PlanRequest? Oracle(string statement, bool analyze) => analyze
        ? null
        : new(
            [
                $"EXPLAIN PLAN SET STATEMENT_ID = '{OracleStatementId}' FOR {statement}",
                "SELECT ID, PARENT_ID, OPERATION, OPTIONS, OBJECT_OWNER, OBJECT_NAME, OBJECT_TYPE, OBJECT_ALIAS, COST, CARDINALITY, BYTES, "
                + "CPU_COST, IO_COST, PARTITION_START, PARTITION_STOP, QBLOCK_NAME, ACCESS_PREDICATES, FILTER_PREDICATES FROM PLAN_TABLE "
                + $"WHERE STATEMENT_ID = '{OracleStatementId}' AND PLAN_ID = (SELECT MAX(PLAN_ID) FROM PLAN_TABLE WHERE STATEMENT_ID = '{OracleStatementId}') ORDER BY ID",
            ],
            PlanFormat.OraclePlanRows,
            false);
}
