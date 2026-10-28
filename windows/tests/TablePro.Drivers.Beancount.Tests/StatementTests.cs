namespace TablePro.Drivers.Beancount.Tests;

public sealed class StatementTests
{
    [Theory]
    [InlineData("BQL: SELECT account", "SELECT account")]
    [InlineData("  bql BALANCES  ", "BALANCES")]
    [InlineData("Bql:JOURNAL 'Assets:Checking'", "JOURNAL 'Assets:Checking'")]
    [InlineData("SELECT * FROM bql", null)]
    [InlineData("bqlx SELECT", null)]
    [InlineData("bql", null)]
    public void BqlPrefix(string statement, string? expected) => Assert.Equal(expected, BeancountStatements.ExtractBql(statement));

    [Theory]
    [InlineData("SELECT * FROM transactions", true)]
    [InlineData("with t as (select 1) select * from t", true)]
    [InlineData("PRAGMA table_info(postings)", true)]
    [InlineData("pragma database_list", true)]
    [InlineData("EXPLAIN QUERY PLAN SELECT 1", true)]
    [InlineData("/* note */ -- more\n SELECT 1", true)]
    [InlineData("", true)]
    [InlineData("DELETE FROM transactions", false)]
    [InlineData("PRAGMA query_only = OFF", false)]
    [InlineData("SELECT 1; DROP TABLE postings", false)]
    [InlineData("ATTACH 'C:\\x.db' AS x", false)]
    [InlineData("CREATE TEMP TABLE t (a)", false)]
    public void OnlyReadsRun(string sql, bool readOnly) => Assert.Equal(readOnly, BeancountStatements.IsReadOnly(sql));
}
