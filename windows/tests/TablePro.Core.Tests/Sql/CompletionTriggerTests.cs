using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class CompletionTriggerTests
{
    [Theory]
    [InlineData("SELECT SUM(total) AS revenue")]
    [InlineData("SELECT SUM(total) AS rev")]
    [InlineData("SELECT * FROM orders AS o")]
    [InlineData("WITH recent AS")]
    public void ANameBeingMadeUpAfterAsOpensNoListByItself(string text) =>
        Assert.Equal(!text.EndsWith("AS", StringComparison.Ordinal), SqlCompletion.SuppressesAutomatic(text, text.Length, SqliteDialect.Instance));

    [Theory]
    [InlineData("SELECT CAST(total AS INT")]
    [InlineData("SELECT o.")]
    [InlineData("SELECT o.sta")]
    [InlineData("SELECT * FROM ord")]
    [InlineData("SELECT sta")]
    public void OtherPositionsStillOpenTheList(string text) =>
        Assert.False(SqlCompletion.SuppressesAutomatic(text, text.Length, SqliteDialect.Instance));

    [Theory]
    [InlineData("-- Delivered orders and their line items")]
    [InlineData("SELECT 1 /* the order items")]
    [InlineData("SELECT * FROM orders WHERE status = 'deliv")]
    public void WordsInCommentsAndStringsOpenNoListByThemselves(string text) =>
        Assert.True(SqlCompletion.SuppressesAutomatic(text, text.Length, SqliteDialect.Instance));

    [Theory]
    [InlineData("-- revenue by country\nSELECT cou")]
    [InlineData("SELECT /* note */ cou")]
    [InlineData("SELECT * FROM \"ord")]
    [InlineData("-- Delivered orders and their line items\nSELECT o.id\nFROM orders o\nWHERE o.")]
    [InlineData("-- Delivered orders and their line items\r\nSELECT o.id\r\nFROM orders o\r\nWHERE o.s")]
    public void CodeAfterACommentOrInAQuotedNameStillOpensTheList(string text) =>
        Assert.False(SqlCompletion.SuppressesAutomatic(text, text.Length, SqliteDialect.Instance));

    [Fact]
    public void AnAliasInsideASubqueryIsStillANewName()
    {
        const string text = "SELECT * FROM (SELECT id AS ident";

        Assert.True(SqlCompletion.SuppressesAutomatic(text, text.Length, SqliteDialect.Instance));
    }
}
