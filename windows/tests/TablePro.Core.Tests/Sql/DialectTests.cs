using System.Globalization;
using TablePro.Core.Connections;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class DialectTests
{
    private static SqlDialect D(string name) => SqlLexerTests.DialectByName(name);

    [Theory]
    [InlineData(DatabaseEngine.PostgreSql, "PostgreSQL")]
    [InlineData(DatabaseEngine.MySql, "MySQL")]
    [InlineData(DatabaseEngine.MariaDb, "MySQL")]
    [InlineData(DatabaseEngine.SqlServer, "SQL Server")]
    [InlineData(DatabaseEngine.Sqlite, "SQLite")]
    [InlineData(DatabaseEngine.DuckDb, "DuckDB")]
    public void EachEngineHasADialect(DatabaseEngine engine, string name)
    {
        var dialect = SqlDialects.For(engine);

        Assert.Equal(name, dialect.Name);
        Assert.Same(D(name), dialect);
    }

    [Fact]
    public void UnknownEngineHasNoDialect() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => SqlDialects.For((DatabaseEngine)99));

    [Theory]
    [InlineData("PostgreSQL", "a\"b", "\"a\"\"b\"")]
    [InlineData("PostgreSQL", "plain", "\"plain\"")]
    [InlineData("MySQL", "a`b", "`a``b`")]
    [InlineData("MySQL", "a\"b", "`a\"b`")]
    [InlineData("SQL Server", "a]b", "[a]]b]")]
    [InlineData("SQL Server", "a[b", "[a[b]")]
    [InlineData("SQLite", "my \"col\"", "\"my \"\"col\"\"\"")]
    [InlineData("DuckDB", "", "\"\"")]
    public void QuoteIdentifierDoublesTheClosingQuote(string dialect, string identifier, string expected) =>
        Assert.Equal(expected, D(dialect).QuoteIdentifier(identifier));

    [Fact]
    public void GoogleSqlAndSurrealQlEscapeBackticksWithABackslash()
    {
        Assert.Equal("`a\\`b\\\\c`", BigQueryDialect.Instance.QuoteIdentifier("a`b\\c"));
        Assert.Equal("`a\\`b`", SpannerDialect.Instance.QuoteIdentifier("a`b"));
        Assert.Equal("`a\\`b`", SurrealQlDialect.Instance.QuoteIdentifier("a`b"));
    }

    [Theory]
    [InlineData("PostgreSQL", "public", "t", "\"public\".\"t\"")]
    [InlineData("PostgreSQL", null, "t", "\"t\"")]
    [InlineData("PostgreSQL", "", "t", "\"t\"")]
    [InlineData("SQL Server", "dbo", "Order Details", "[dbo].[Order Details]")]
    [InlineData("MySQL", "shop", "orders", "`shop`.`orders`")]
    public void QualifyQuotesEachPart(string dialect, string? schema, string name, string expected) =>
        Assert.Equal(expected, D(dialect).Qualify(new ObjectName(schema, name)));

    [Theory]
    [InlineData("PostgreSQL", "TRUE", "FALSE")]
    [InlineData("MySQL", "TRUE", "FALSE")]
    [InlineData("SQL Server", "1", "0")]
    [InlineData("SQLite", "1", "0")]
    [InlineData("DuckDB", "TRUE", "FALSE")]
    public void BooleanLiterals(string dialect, string yes, string no)
    {
        Assert.Equal(yes, D(dialect).Literal(true));
        Assert.Equal(no, D(dialect).Literal(false));
    }

    [Theory]
    [InlineData("PostgreSQL", "'\\x0AFF'::bytea")]
    [InlineData("MySQL", "X'0AFF'")]
    [InlineData("SQL Server", "0x0AFF")]
    [InlineData("SQLite", "X'0AFF'")]
    [InlineData("DuckDB", "X'0AFF'")]
    public void BinaryLiterals(string dialect, string expected) =>
        Assert.Equal(expected, D(dialect).Literal(new byte[] { 0x0A, 0xFF }));

    [Theory]
    [InlineData("PostgreSQL", "it's", "'it''s'")]
    [InlineData("PostgreSQL", "a\\b", "'a\\b'")]
    [InlineData("MySQL", "it's", "'it''s'")]
    [InlineData("MySQL", "a\\b", "'a\\\\b'")]
    [InlineData("MySQL", "a\\'b", "'a\\\\''b'")]
    [InlineData("SQL Server", "it's", "N'it''s'")]
    [InlineData("SQL Server", "日本", "N'日本'")]
    [InlineData("SQLite", "it's", "'it''s'")]
    [InlineData("DuckDB", "", "''")]
    public void StringLiterals(string dialect, string value, string expected) =>
        Assert.Equal(expected, D(dialect).Literal(value));

    [Theory]
    [InlineData("PostgreSQL")]
    [InlineData("MySQL")]
    [InlineData("SQL Server")]
    [InlineData("SQLite")]
    [InlineData("DuckDB")]
    public void NullLiterals(string dialect)
    {
        Assert.Equal("NULL", D(dialect).Literal(null));
        Assert.Equal("NULL", D(dialect).Literal(DBNull.Value));
    }

    [Theory]
    [InlineData("PostgreSQL", "")]
    [InlineData("SQL Server", "N")]
    public void TemporalLiteralsAreQuotedIsoText(string dialect, string prefix)
    {
        var d = D(dialect);
        string Q(string text) => $"{prefix}'{text}'";

        Assert.Equal(Q("2024-01-02"), d.Literal(new DateTime(2024, 1, 2)));
        Assert.Equal(Q("2024-01-02 03:04:05"), d.Literal(new DateTime(2024, 1, 2, 3, 4, 5)));
        Assert.Equal(Q("2024-01-02 03:04:05.12345"), d.Literal(new DateTime(2024, 1, 2, 3, 4, 5).AddTicks(1_234_500)));
        Assert.Equal(Q("2024-01-02 03:04:05+02:00"), d.Literal(new DateTimeOffset(2024, 1, 2, 3, 4, 5, TimeSpan.FromHours(2))));
        Assert.Equal(Q("2024-01-02 03:04:05.5-05:30"), d.Literal(new DateTimeOffset(2024, 1, 2, 3, 4, 5, 500, TimeSpan.FromMinutes(-330))));
        Assert.Equal(Q("2024-01-02"), d.Literal(new DateOnly(2024, 1, 2)));
        Assert.Equal(Q("13:14:15"), d.Literal(new TimeOnly(13, 14, 15)));
        Assert.Equal(Q("13:14:15.25"), d.Literal(new TimeOnly(13, 14, 15, 250)));
        Assert.Equal(Q("01:02:03"), d.Literal(new TimeSpan(1, 2, 3)));
        Assert.Equal(Q("1.02:03:04"), d.Literal(new TimeSpan(1, 2, 3, 4)));
    }

    [Fact]
    public void GuidLiteralIsQuotedText()
    {
        var id = Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e");

        Assert.Equal("'0f8fad5b-d9cb-469f-a165-70867728950e'", PostgreSqlDialect.Instance.Literal(id));
        Assert.Equal("N'0f8fad5b-d9cb-469f-a165-70867728950e'", SqlServerDialect.Instance.Literal(id));
    }

    public static TheoryData<object, string> NumberCases => new()
    {
        { 42, "42" },
        { -7L, "-7" },
        { (short)12, "12" },
        { (byte)255, "255" },
        { (sbyte)-8, "-8" },
        { (ushort)65535, "65535" },
        { 4_000_000_000u, "4000000000" },
        { ulong.MaxValue, "18446744073709551615" },
        { 1.50m, "1.50" },
        { -0.001m, "-0.001" },
        { 1.5f, "1.5" },
        { 0.1, "0.1" },
        { 1e20, "1E+20" },
        { 12345.678, "12345.678" },
    };

    [Theory]
    [MemberData(nameof(NumberCases))]
    public void NumberLiteralsAreUnquotedInvariantText(object value, string expected)
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
        try
        {
            Assert.Equal(expected, PostgreSqlDialect.Instance.Literal(value));
            Assert.Equal(expected, SqlServerDialect.Instance.Literal(value));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Fact]
    public void CharLiteralIsQuoted()
    {
        Assert.Equal("'x'", PostgreSqlDialect.Instance.Literal('x'));
        Assert.Equal("''''", SqliteDialect.Instance.Literal('\''));
        Assert.Equal("N'x'", SqlServerDialect.Instance.Literal('x'));
    }

    [Fact]
    public void OtherValuesAreQuotedText() =>
        Assert.Equal("'https://example.com/a''b'", PostgreSqlDialect.Instance.Literal(new Uri("https://example.com/a'b")));

    [Theory]
    [InlineData("PostgreSQL", "@p0", "@p12")]
    [InlineData("MySQL", "@p0", "@p12")]
    [InlineData("SQL Server", "@p0", "@p12")]
    [InlineData("SQLite", "@p0", "@p12")]
    [InlineData("DuckDB", "$p0", "$p12")]
    public void ParameterNames(string dialect, string first, string twelfth)
    {
        Assert.Equal(first, D(dialect).ParameterName(0));
        Assert.Equal(twelfth, D(dialect).ParameterName(12));
    }

    [Theory]
    [InlineData("PostgreSQL", "ILIKE", "\"c\"::text")]
    [InlineData("MySQL", "LIKE", "CAST(\"c\" AS CHAR)")]
    [InlineData("SQL Server", "LIKE", "CAST(\"c\" AS NVARCHAR(4000))")]
    [InlineData("SQLite", "LIKE", "CAST(\"c\" AS TEXT)")]
    [InlineData("DuckDB", "ILIKE", "\"c\"::VARCHAR")]
    public void CaseInsensitiveLikeAndTextCast(string dialect, string like, string cast)
    {
        Assert.Equal(like, D(dialect).CaseInsensitiveLike);
        Assert.Equal(cast, D(dialect).CastToText("\"c\""));
    }

    [Fact]
    public void ExplainStatementsPerDialect()
    {
        Assert.Equal(["EXPLAIN (FORMAT TEXT) SELECT 1"], PostgreSqlDialect.Instance.Explain("SELECT 1"));
        Assert.Equal(["EXPLAIN SELECT 1"], MySqlDialect.Instance.Explain("SELECT 1"));
        Assert.Equal(["SET SHOWPLAN_TEXT ON", "SELECT 1", "SET SHOWPLAN_TEXT OFF"], SqlServerDialect.Instance.Explain("SELECT 1"));
        Assert.Equal(["EXPLAIN QUERY PLAN SELECT 1"], SqliteDialect.Instance.Explain("SELECT 1"));
        Assert.Equal(["EXPLAIN SELECT 1"], DuckDbDialect.Instance.Explain("SELECT 1"));
    }

    [Fact]
    public void ScriptRulesPerDialect()
    {
        Assert.Equal("GO", SqlServerDialect.Instance.BatchSeparator);
        Assert.Null(PostgreSqlDialect.Instance.BatchSeparator);
        Assert.True(MySqlDialect.Instance.SupportsDelimiterDirective);
        Assert.False(PostgreSqlDialect.Instance.SupportsDelimiterDirective);
        Assert.True(SqliteDialect.Instance.KeepsTriggerBodies);
        Assert.False(DuckDbDialect.Instance.KeepsTriggerBodies);
    }
}
