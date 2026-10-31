using TablePro.Core.Connections;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class BeancountDialectTests
{
    [Theory]
    [InlineData("BQL: SELECT account, sum(position)", StatementKind.Read)]
    [InlineData("  bql select date, narration", StatementKind.Read)]
    [InlineData("SELECT * FROM postings", StatementKind.Read)]
    [InlineData("DELETE FROM postings", StatementKind.Write)]
    [InlineData("bqlx SELECT 1", StatementKind.Unknown)]
    public void BqlStatementsAreReads(string statement, StatementKind expected) =>
        Assert.Equal(expected, BeancountDialect.Instance.Classify(statement));

    [Fact]
    public void BeancountKeepsSqliteSyntax()
    {
        var dialect = SqlDialects.For(DatabaseEngine.Beancount);

        Assert.Same(BeancountDialect.Instance, dialect);
        Assert.IsAssignableFrom<SqliteDialect>(dialect);
        Assert.Equal("\"t\"", dialect.QuoteIdentifier("t"));
    }
}
