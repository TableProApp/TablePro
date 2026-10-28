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
}

public sealed class MySqlDialect : SqlDialect
{
    public static readonly MySqlDialect Instance = new();

    private MySqlDialect()
    {
    }

    public override string Name => "MySQL";

    public override SqlLexerFeatures LexerFeatures =>
        SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.HashComments | SqlLexerFeatures.BackslashEscapes
        | SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.DashCommentNeedsSpace;

    public override bool SupportsDelimiterDirective => true;

    public override char IdentifierOpen => '`';

    public override char IdentifierClose => '`';

    public override string StringLiteral(string value) =>
        string.Concat("'", value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "''", StringComparison.Ordinal), "'");

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS CHAR)";
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

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS NVARCHAR(4000))";

    // SQL Server's LIKE reads [abc] as a character class.
    public override string LikeWildcards => "%_[";
}

public sealed class SqliteDialect : SqlDialect
{
    public static readonly SqliteDialect Instance = new();

    private SqliteDialect()
    {
    }

    public override string Name => "SQLite";

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.BacktickIdentifiers | SqlLexerFeatures.BracketIdentifiers;

    public override bool KeepsTriggerBodies => true;

    public override string BooleanLiteral(bool value) => value ? "1" : "0";

    public override IReadOnlyList<string> Explain(string statement) => ["EXPLAIN QUERY PLAN " + statement];

    public override string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS TEXT)";
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
}

public static class SqlDialects
{
    public static SqlDialect For(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => PostgreSqlDialect.Instance,
        DatabaseEngine.MySql or DatabaseEngine.MariaDb => MySqlDialect.Instance,
        DatabaseEngine.SqlServer => SqlServerDialect.Instance,
        DatabaseEngine.Sqlite => SqliteDialect.Instance,
        DatabaseEngine.DuckDb => DuckDbDialect.Instance,
        _ => throw new ArgumentOutOfRangeException(nameof(engine), engine, null),
    };
}
