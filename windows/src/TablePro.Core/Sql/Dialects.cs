using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using TablePro.Core.Connections;

namespace TablePro.Core.Sql;

public sealed class PostgreSqlDialect : SqlDialect
{
    public static readonly PostgreSqlDialect Instance = new();

    private PostgreSqlDialect()
    {
    }

    public override string Name => "PostgreSQL";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.DollarQuotes | SqlLexerFeatures.NestedBlockComments;

    public override string BinaryLiteral(ReadOnlySpan<byte> value) => string.Concat("'\\x", Convert.ToHexString(value), "'::bytea");

    public override string CaseInsensitiveLike => "ILIKE";

    public override string CastToText(string quotedColumn) => quotedColumn + "::text";

    public override IReadOnlyList<string> Explain(string statement) => ["EXPLAIN (FORMAT TEXT) " + statement];

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) => Plans.PlanStatements.PostgreSql(statement, analyze);
}

/// <summary>MySQL and MariaDB, which share their syntax; MariaDB asks for its measured plan in a statement of its own.</summary>
public sealed class MySqlDialect : SqlDialect
{
    public static readonly MySqlDialect Instance = new(mariaDb: false);

    public static readonly MySqlDialect MariaDb = new(mariaDb: true);

    private readonly bool _mariaDb;

    private MySqlDialect(bool mariaDb)
    {
        _mariaDb = mariaDb;
    }

    public override string Name => _mariaDb ? "MariaDB" : "MySQL";

    public override SqlLexerFeatures LexerFeatures =>
        SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.HashComments | SqlLexerFeatures.BackslashEscapes
        | SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.DashCommentNeedsSpace;

    public override bool SupportsDelimiterDirective => true;

    public override char IdentifierOpen => '`';

    public override char IdentifierClose => '`';

    public override string StringLiteral(string value) =>
        string.Concat("'", value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "''", StringComparison.Ordinal), "'");

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS CHAR)";

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) =>
        _mariaDb ? Plans.PlanStatements.MariaDb(statement, analyze) : Plans.PlanStatements.MySql(statement, analyze);
}

public sealed class SqlServerDialect : SqlDialect
{
    public static readonly SqlServerDialect Instance = new();

    private SqlServerDialect()
    {
    }

    public override string Name => "SQL Server";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.BracketIdentifiers | SqlLexerFeatures.NestedBlockComments;

    public override string? BatchSeparator => "GO";

    public override char IdentifierOpen => '[';

    public override char IdentifierClose => ']';

    public override string StringLiteral(string value) => string.Concat("N'", value.Replace("'", "''", StringComparison.Ordinal), "'");

    public override string BinaryLiteral(ReadOnlySpan<byte> value) => "0x" + Convert.ToHexString(value);

    public override string BooleanLiteral(bool value) => value ? "1" : "0";

    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy)
    {
        // OFFSET ... FETCH needs an ORDER BY; ordering by a constant keeps the server's own order.
        if (!hasOrderBy)
        {
            sql.Append(" ORDER BY (SELECT NULL)");
        }

        sql.Append(CultureInfo.InvariantCulture, $" OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY");
    }

    // SHOWPLAN must be the only statement in its batch, so it is switched on and off around the statement.
    public override IReadOnlyList<string> Explain(string statement) => ["SET SHOWPLAN_TEXT ON", statement, "SET SHOWPLAN_TEXT OFF"];

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) => Plans.PlanStatements.SqlServer(statement, analyze);

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS NVARCHAR(4000))";

    // SQL Server's LIKE reads [abc] as a character class.
    public override string LikeWildcards => "%_[";
}

public class SqliteDialect : SqlDialect
{
    public static readonly SqliteDialect Instance = new();

    private protected SqliteDialect()
    {
    }

    public override string Name => "SQLite";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.BracketIdentifiers;

    public override bool KeepsTriggerBodies => true;

    public override string BooleanLiteral(bool value) => value ? "1" : "0";

    public override IReadOnlyList<string> Explain(string statement) => ["EXPLAIN QUERY PLAN " + statement];

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) => Plans.PlanStatements.Sqlite(statement, analyze);

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS TEXT)";
}

/// <summary>A Beancount ledger projected into SQLite. Statements prefixed <c>BQL:</c> or <c>BQL </c>, in any case, go to rledger's query language, which only reads.</summary>
public sealed class BeancountDialect : SqliteDialect
{
    public static new readonly BeancountDialect Instance = new();

    private BeancountDialect()
    {
    }

    public override string Name => "Beancount";

    public static bool IsBql(ReadOnlySpan<char> statement)
    {
        var text = statement.TrimStart();
        return text.Length >= 4 && text.StartsWith("bql", StringComparison.OrdinalIgnoreCase) && text[3] is ':' or ' ';
    }

    public override StatementKind Classify(string statement) => IsBql(statement) ? StatementKind.Read : base.Classify(statement);
}

public sealed class DuckDbDialect : SqlDialect
{
    public static readonly DuckDbDialect Instance = new();

    private DuckDbDialect()
    {
    }

    public override string Name => "DuckDB";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.DollarQuotes | SqlLexerFeatures.NestedBlockComments;

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"$p{index}");

    public override string CaseInsensitiveLike => "ILIKE";

    public override string CastToText(string quotedColumn) => quotedColumn + "::VARCHAR";

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) => Plans.PlanStatements.DuckDb(statement, analyze);
}

public sealed class ClickHouseDialect : SqlDialect
{
    public static readonly ClickHouseDialect Instance = new();

    private ClickHouseDialect()
    {
    }

    public override string Name => "ClickHouse";

    public override SqlLexerFeatures LexerFeatures =>
        SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.NestedBlockComments | SqlLexerFeatures.HashComments | SqlLexerFeatures.DoubleSlashComments | SqlLexerFeatures.DollarQuotes;

    public override char IdentifierOpen => '`';

    public override char IdentifierClose => '`';

    public override string StringLiteral(string value) =>
        string.Concat("'", value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "\\'", StringComparison.Ordinal), "'");

    // The driver rewrites @pN to ClickHouse's {pN:String}; the @ makes it a parameter token so change previews fill it in.
    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"@p{index}");

    public override string CastToText(string quotedColumn) => $"toString({quotedColumn})";

    public override string CaseInsensitiveLike => "ILIKE";

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) => Plans.PlanStatements.ClickHouse(statement, analyze);
}

public sealed class OracleDialect : SqlDialect
{
    public static readonly OracleDialect Instance = new();

    private OracleDialect()
    {
    }

    public override string Name => "Oracle";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.None;

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $":p{index}");

    // PL/SQL blocks hold semicolons of their own and end at a lone slash, as in SQL*Plus.
    public override ImmutableArray<SqlStatement> Split(string text) => OracleScript.Split(text);

    public override string BinaryLiteral(ReadOnlySpan<byte> value) => string.Concat("HEXTORAW('", Convert.ToHexString(value), "')");

    public override string BooleanLiteral(bool value) => value ? "1" : "0";

    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy) =>
        sql.Append(CultureInfo.InvariantCulture, $" OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY");

    public override IReadOnlyList<string> Explain(string statement) =>
        ["EXPLAIN PLAN FOR " + statement, "SELECT PLAN_TABLE_OUTPUT FROM TABLE(DBMS_XPLAN.DISPLAY())"];

    public override Plans.PlanRequest? PlanStatements(string statement, bool analyze) => Plans.PlanStatements.Oracle(statement, analyze);

    public override string CastToText(string quotedColumn) => $"TO_CHAR({quotedColumn})";
}

/// <summary>CQL for Cassandra and ScyllaDB. It has no OFFSET; the driver pages with the server's paging state.</summary>
public sealed class CqlDialect : SqlDialect
{
    public static readonly CqlDialect Instance = new();

    private CqlDialect()
    {
    }

    public override string Name => "CQL";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.DoubleSlashComments | SqlLexerFeatures.DollarQuotes;

    public override string LineComment => "--";

    // A batch holds semicolons of its own and is one request, from BEGIN [UNLOGGED | COUNTER] BATCH to APPLY BATCH.
    public override ImmutableArray<SqlStatement> Split(string text)
    {
        var parts = SqlScript.SplitSql(text, this);
        var merged = ImmutableArray.CreateBuilder<SqlStatement>(parts.Length);
        var batchStart = -1;
        foreach (var part in parts)
        {
            if (batchStart < 0 && StartsBatch(part.Text))
            {
                batchStart = part.Start;
            }

            if (batchStart < 0)
            {
                merged.Add(part);
            }
            else if (part.Text.TrimEnd().EndsWith("APPLY BATCH", StringComparison.OrdinalIgnoreCase))
            {
                merged.Add(new SqlStatement(batchStart, part.End - batchStart, text[batchStart..part.End]));
                batchStart = -1;
            }
        }

        if (batchStart >= 0)
        {
            merged.Add(new SqlStatement(batchStart, text.Length - batchStart, text[batchStart..].TrimEnd()));
        }

        return merged.ToImmutable();
    }

    private static bool StartsBatch(string statement)
    {
        var words = statement.AsSpan().TrimStart();
        if (!words.StartsWith("BEGIN", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var rest = words[5..].TrimStart();
        if (rest.StartsWith("UNLOGGED", StringComparison.OrdinalIgnoreCase) || rest.StartsWith("COUNTER", StringComparison.OrdinalIgnoreCase))
        {
            rest = rest[(rest.IndexOf(' ') is var space and > 0 ? space : rest.Length)..].TrimStart();
        }

        return rest.StartsWith("BATCH", StringComparison.OrdinalIgnoreCase);
    }

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"p{index}");

    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy) =>
        sql.Append(CultureInfo.InvariantCulture, $" LIMIT {offset + limit}");

    public override string BinaryLiteral(ReadOnlySpan<byte> value) => "0x" + Convert.ToHexString(value);

    public override IReadOnlyList<string> Explain(string statement) => [];
}

public sealed class SnowflakeDialect : SqlDialect
{
    public static readonly SnowflakeDialect Instance = new();

    private SnowflakeDialect()
    {
    }

    public override string Name => "Snowflake";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.DollarQuotes | SqlLexerFeatures.DoubleSlashComments;

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $":{index + 1}");

    public override string CaseInsensitiveLike => "ILIKE";

    public override string CastToText(string quotedColumn) => $"TO_VARCHAR({quotedColumn})";
}

public sealed class BigQueryDialect : SqlDialect
{
    public static readonly BigQueryDialect Instance = new();

    private BigQueryDialect()
    {
    }

    public override string Name => "GoogleSQL";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.HashComments | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.DoubleQuotedStrings;

    public override char IdentifierOpen => '`';

    public override char IdentifierClose => '`';

    protected override bool BackslashEscapesIdentifiers => true;

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"@p{index}");

    public override string BinaryLiteral(ReadOnlySpan<byte> value) => string.Concat("FROM_HEX('", Convert.ToHexString(value), "')");

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS STRING)";

    /// <summary>A dry run reports what a query would scan, which is BigQuery's plan.</summary>
    public override IReadOnlyList<string> Explain(string statement) => [];
}

public sealed class TrinoDialect : SqlDialect
{
    public static readonly TrinoDialect Instance = new();

    private TrinoDialect()
    {
    }

    public override string Name => "Trino";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.None;

    public override string ParameterName(int index) => "?";

    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy) =>
        sql.Append(CultureInfo.InvariantCulture, $" OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY");
}

public sealed class SpannerDialect : SqlDialect
{
    public static readonly SpannerDialect Instance = new();

    private SpannerDialect()
    {
    }

    public override string Name => "Spanner";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.HashComments | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.DoubleQuotedStrings;

    public override char IdentifierOpen => '`';

    public override char IdentifierClose => '`';

    protected override bool BackslashEscapesIdentifiers => true;

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"@p{index}");

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS STRING)";

    public override IReadOnlyList<string> Explain(string statement) => [];
}

public sealed class TeradataDialect : SqlDialect
{
    public static readonly TeradataDialect Instance = new();

    private TeradataDialect()
    {
    }

    public override string Name => "Teradata";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.None;

    public override string ParameterName(int index) => "?";

    // Teradata has no OFFSET; QUALIFY over ROW_NUMBER is how its own tools page.
    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy) =>
        sql.Append(CultureInfo.InvariantCulture, $" QUALIFY ROW_NUMBER() OVER (ORDER BY 1) BETWEEN {offset + 1} AND {offset + limit}");

    /// <summary>
    /// The first page is <c>TOP n</c>, which stops reading once it has its rows. A later page numbers the rows over
    /// the browse's own sort, so the window and the page agree on the order; numbering over a constant lets each page
    /// draw from a different order.
    /// </summary>
    public override SqlCommandSpec BuildBrowse(Browse.BrowseRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var sql = new StringBuilder("SELECT ");
        if (request.Offset <= 0 && request.Limit is > 0 and < int.MaxValue)
        {
            sql.Append(CultureInfo.InvariantCulture, $"TOP {request.Limit} ");
        }

        sql.Append("* FROM ").Append(Qualify(request.Table));
        var parameters = new List<KeyValuePair<string, object?>>();
        AppendWhere(sql, request.Filter, parameters);

        var order = new StringBuilder();
        foreach (var sort in request.Sort)
        {
            order.Append(order.Length == 0 ? string.Empty : ", ").Append(QuoteIdentifier(sort.Column)).Append(sort.Descending ? " DESC" : " ASC");
        }

        // QUALIFY comes before ORDER BY in Teradata's clause order; the outer ORDER BY keeps the page's rows sorted.
        if (request.Offset > 0)
        {
            var window = order.Length > 0 ? order.ToString() : "1";
            sql.Append(CultureInfo.InvariantCulture, $" QUALIFY ROW_NUMBER() OVER (ORDER BY {window}) BETWEEN {request.Offset + 1L} AND {request.Offset + (long)Math.Max(request.Limit, 1)}");
        }

        if (order.Length > 0)
        {
            sql.Append(" ORDER BY ").Append(order);
        }

        return new SqlCommandSpec(sql.ToString(), parameters);
    }
}

public sealed class HanaDialect : SqlDialect
{
    public static readonly HanaDialect Instance = new();

    private HanaDialect()
    {
    }

    public override string Name => "SAP HANA";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.None;

    public override string ParameterName(int index) => "?";

    public override IReadOnlyList<string> Explain(string statement) => ["EXPLAIN PLAN FOR " + statement, "SELECT * FROM EXPLAIN_PLAN_TABLE"];
}

/// <summary>DynamoDB's PartiQL: SQL-shaped reads and writes keyed by the table's key; no joins, no OFFSET.</summary>
public sealed class PartiQlDialect : SqlDialect
{
    public static readonly PartiQlDialect Instance = new();

    private PartiQlDialect()
    {
    }

    public override string Name => "PartiQL";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.None;

    public override string ParameterName(int index) => "?";

    public override IReadOnlyList<string> Explain(string statement) => [];

    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy)
    {
    }
}

/// <summary>SurrealQL: SQL-shaped, with DEFINE and REMOVE for structure and RELATE for graph edges.</summary>
public sealed class SurrealQlDialect : SqlDialect
{
    public static readonly SurrealQlDialect Instance = new();

    private static readonly System.Collections.Frozen.FrozenSet<string> Words = System.Collections.Frozen.FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        ["SELECT", "FROM", "WHERE", "CREATE", "UPDATE", "UPSERT", "DELETE", "INSERT", "INTO", "RELATE", "CONTENT", "MERGE", "PATCH", "SET", "RETURN", "DEFINE", "REMOVE",
         "TABLE", "FIELD", "INDEX", "NAMESPACE", "DATABASE", "USE", "NS", "DB", "INFO", "FOR", "LIMIT", "START", "ORDER", "BY", "GROUP", "SPLIT", "FETCH", "LET", "IF", "ELSE", "THEN", "END",
         "BEGIN", "COMMIT", "CANCEL", "TRANSACTION", "LIVE", "KILL", "SCHEMAFULL", "SCHEMALESS", "TYPE", "ASSERT", "VALUE", "DEFAULT", "NONE", "NULL", "AND", "OR", "NOT", "IN", "CONTAINS"]);

    private SurrealQlDialect()
    {
    }

    public override string Name => "SurrealQL";

    public override bool IsSql => false;

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.BackslashEscapes | SqlLexerFeatures.DoubleSlashComments | SqlLexerFeatures.HashComments;

    public override char IdentifierOpen => '`';

    public override char IdentifierClose => '`';

    protected override bool BackslashEscapesIdentifiers => true;

    public override string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"$p{index}");

    public override IReadOnlyList<string> Explain(string statement) => [statement.TrimEnd().TrimEnd(';') + " EXPLAIN"];

    public override IEnumerable<string> CompletionKeywords => Words;

    public override bool IsKeyword(ReadOnlySpan<char> word) => Words.Contains(word.ToString());

    public override void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy) =>
        sql.Append(CultureInfo.InvariantCulture, $" LIMIT {limit} START {offset}");

    public override StatementKind Classify(string statement)
    {
        var words = CommandWords.Read(statement.TrimStart(), 1);
        return words.Count == 0 ? StatementKind.Unknown : words[0].ToUpperInvariant() switch
        {
            "SELECT" or "INFO" or "RETURN" or "SHOW" => StatementKind.Read,
            "CREATE" or "UPDATE" or "UPSERT" or "DELETE" or "INSERT" or "RELATE" => StatementKind.Write,
            "DEFINE" or "REMOVE" or "ALTER" => StatementKind.Ddl,
            "USE" or "LET" => StatementKind.Session,
            "BEGIN" or "COMMIT" or "CANCEL" => StatementKind.Transaction,
            _ => StatementKind.Unknown,
        };
    }
}

public static class SqlDialects
{
    public static SqlDialect For(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql or DatabaseEngine.CockroachDb or DatabaseEngine.Redshift or DatabaseEngine.PGlite => PostgreSqlDialect.Instance,
        DatabaseEngine.MySql or DatabaseEngine.TiDb or DatabaseEngine.OceanBase or DatabaseEngine.Databend => MySqlDialect.Instance,
        DatabaseEngine.MariaDb => MySqlDialect.MariaDb,
        DatabaseEngine.SqlServer => SqlServerDialect.Instance,
        DatabaseEngine.Sqlite or DatabaseEngine.LibSql or DatabaseEngine.Turso or DatabaseEngine.CloudflareD1 or DatabaseEngine.CloudflareR2Sql => SqliteDialect.Instance,
        DatabaseEngine.Beancount => BeancountDialect.Instance,
        DatabaseEngine.DuckDb => DuckDbDialect.Instance,
        DatabaseEngine.Redis => RedisDialect.Instance,
        DatabaseEngine.MongoDb => MongoDialect.Instance,
        DatabaseEngine.ClickHouse => ClickHouseDialect.Instance,
        DatabaseEngine.Oracle or DatabaseEngine.Dameng => OracleDialect.Instance,
        DatabaseEngine.Cassandra or DatabaseEngine.ScyllaDb => CqlDialect.Instance,
        DatabaseEngine.Snowflake => SnowflakeDialect.Instance,
        DatabaseEngine.BigQuery => BigQueryDialect.Instance,
        DatabaseEngine.Trino => TrinoDialect.Instance,
        DatabaseEngine.Spanner => SpannerDialect.Instance,
        DatabaseEngine.Teradata => TeradataDialect.Instance,
        DatabaseEngine.SapHana => HanaDialect.Instance,
        DatabaseEngine.DynamoDb => PartiQlDialect.Instance,
        DatabaseEngine.Elasticsearch => ElasticsearchDialect.Instance,
        DatabaseEngine.Typesense => TypesenseDialect.Instance,
        DatabaseEngine.Weaviate => GraphQlDialect.Instance,
        DatabaseEngine.Kafka => KafkaDialect.Instance,
        DatabaseEngine.Etcd => EtcdDialect.Instance,
        DatabaseEngine.SurrealDb => SurrealQlDialect.Instance,
        _ => throw new ArgumentOutOfRangeException(nameof(engine), engine, null),
    };
}