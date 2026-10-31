using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Schema;

public sealed class ConstraintTextTests
{
    [Theory]
    [InlineData("((a > 0))", "a > 0")]
    [InlineData("([price]>(0))", "[price]>(0)")]
    [InlineData("(a > 0) AND (b > 0)", "(a > 0) AND (b > 0)")]
    [InlineData("((a > 0) AND (b > 0))", "(a > 0) AND (b > 0)")]
    [InlineData("(name <> ')')", "name <> ')'")]
    [InlineData("a > 0", "a > 0")]
    [InlineData("  ", "")]
    public void StripsOnlyTheParenthesesAroundTheWhole(string text, string expected)
    {
        Assert.Equal(expected, ConstraintText.StripEnclosingParentheses(text));
    }

    [Theory]
    [InlineData("CHECK ((total >= 0))", "total >= 0")]
    [InlineData("CHECK ((total < 1000)) NOT VALID", "total < 1000")]
    [InlineData("CHECK ((status = ANY (ARRAY['a'::text, 'b'::text]))) NO INHERIT", "status = ANY (ARRAY['a'::text, 'b'::text])")]
    [InlineData("total > 0", "total > 0")]
    public void ReadsTheExpressionOutOfACheckClause(string definition, string expected)
    {
        Assert.Equal(expected, ConstraintText.CheckClauseExpression(definition));
    }

    [Fact]
    public void SplitsTheTopLevelEntriesOfACreateTable()
    {
        const string Sql = """
            CREATE TABLE db.t
            (
                `a` UInt32,
                `b` Decimal(18, 2) DEFAULT 0,
                CONSTRAINT c1 CHECK a > 0,
                CONSTRAINT `c,2` CHECK b IN (1, 2)
            )
            ENGINE = MergeTree ORDER BY (a, b)
            """;

        var entries = ConstraintText.CreateTableEntries(Sql, ClickHouseDialect.Instance.LexerFeatures);

        Assert.Equal(["`a` UInt32", "`b` Decimal(18, 2) DEFAULT 0", "CONSTRAINT c1 CHECK a > 0", "CONSTRAINT `c,2` CHECK b IN (1, 2)"], entries);
    }

    [Fact]
    public void AStatementWithoutAColumnListHasNoEntries()
    {
        Assert.Empty(ConstraintText.CreateTableEntries("CREATE TABLE t AS SELECT 1", PostgreSqlDialect.Instance.LexerFeatures));
    }

    [Theory]
    [InlineData("CONSTRAINT \"ck_total\" CHECK (total >= 0)", "ck_total", "total >= 0")]
    [InlineData("CONSTRAINT ck_total CHECK ((total >= 0))", "ck_total", "total >= 0")]
    [InlineData("constraint \"a \"\"b\"\"\" check (x <> '')", "a \"b\"", "x <> ''")]
    public void ReadsANamedCheck(string entry, string name, string expression)
    {
        var check = ConstraintText.ParseCheckEntry(entry, PostgreSqlDialect.Instance.LexerFeatures);

        Assert.NotNull(check);
        Assert.Equal(name, check.Value.Name);
        Assert.Equal(expression, check.Value.Expression);
    }

    [Fact]
    public void AnUnnamedCheckHasNoName()
    {
        var check = ConstraintText.ParseCheckEntry("CHECK (price >= 0)", SqliteDialect.Instance.LexerFeatures);

        Assert.NotNull(check);
        Assert.Null(check.Value.Name);
        Assert.Equal("price >= 0", check.Value.Expression);
    }

    [Theory]
    [InlineData("PRIMARY KEY (id)")]
    [InlineData("CONSTRAINT fk FOREIGN KEY (a) REFERENCES b (id)")]
    [InlineData("CONSTRAINT c ASSUME a > 0")]
    [InlineData("price REAL CHECK (price >= 0)")]
    [InlineData("CHECK")]
    public void OtherEntriesAreNotChecks(string entry)
    {
        Assert.Null(ConstraintText.ParseCheckEntry(entry, ClickHouseDialect.Instance.LexerFeatures));
    }
}
