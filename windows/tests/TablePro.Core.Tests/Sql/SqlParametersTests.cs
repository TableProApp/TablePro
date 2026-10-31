using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class SqlParametersTests
{
    [Fact]
    public void FindsPositionalNamedAndNumberedPlaceholdersButNotVariablesOrStrings()
    {
        const string sql = "SELECT * FROM t WHERE a = ? AND b = :name AND c = $1 AND d = @var AND e = '?' AND f = ?";

        var names = SqlParameters.Find(sql, PostgreSqlDialect.Instance).Select(p => p.Name);

        Assert.Equal(["?1", ":name", "$1", "?2"], names);
    }

    [Fact]
    public void PostgresCastsAreNotNamedParameters()
    {
        Assert.Empty(SqlParameters.Find("SELECT '1'::int, now()::date", PostgreSqlDialect.Instance));
    }

    [Fact]
    public void SubstitutesValuesAsLiterals()
    {
        var values = new Dictionary<string, string?> { [":id"] = "42", [":name"] = "O'Brien", [":gone"] = "NULL", [":flag"] = "true", [":zip"] = "01234" };

        var sql = SqlParameters.Substitute("UPDATE t SET name = :name, gone = :gone, flag = :flag, zip = :zip WHERE id = :id", SqliteDialect.Instance, values);

        Assert.Equal("UPDATE t SET name = 'O''Brien', gone = NULL, flag = 1, zip = '01234' WHERE id = 42", sql);
    }

    [Fact]
    public void DistinctNamesKeepFirstAppearanceOrderAcrossStatements()
    {
        var names = SqlParameters.DistinctNames(["SELECT :b, :a", "SELECT :a, :c"], PostgreSqlDialect.Instance);

        Assert.Equal([":b", ":a", ":c"], names);
    }

    [Fact]
    public void CommandLanguagesHaveNoPrompts()
    {
        Assert.Empty(SqlParameters.Find("db.users.find({ $expr: { $gt: [\"$a\", 1] } })", MongoDialect.Instance));
    }
}
