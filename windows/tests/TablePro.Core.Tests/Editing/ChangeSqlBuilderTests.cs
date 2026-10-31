using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Editing;

public sealed class ChangeSqlBuilderTests
{
    private static readonly ObjectName Table = new("public", "t");

    private static Dictionary<string, object?> Row(params (string Column, object? Value)[] values) =>
        values.ToDictionary(v => v.Column, v => v.Value);

    [Fact]
    public void UpdateSetsValuesAndFiltersByKey()
    {
        var change = new RowUpdate(Row(("id", 7)), Row(("name", "x"), ("age", 3)));

        var spec = ChangeSqlBuilder.Build(PostgreSqlDialect.Instance, Table, change);

        Assert.Equal("UPDATE \"public\".\"t\" SET \"name\" = @p0, \"age\" = @p1 WHERE \"id\" = @p2", spec.Text);
        Assert.Equal(["@p0", "@p1", "@p2"], spec.Parameters.Select(p => p.Key));
        Assert.Equal(["x", 3, 7], spec.Parameters.Select(p => p.Value));
    }

    [Fact]
    public void UpdateCanSetNull()
    {
        var spec = ChangeSqlBuilder.Build(SqliteDialect.Instance, new ObjectName(null, "t"), new RowUpdate(Row(("id", 1)), Row(("note", null))));

        Assert.Equal("UPDATE \"t\" SET \"note\" = @p0 WHERE \"id\" = @p1", spec.Text);
        Assert.Null(spec.Parameters[0].Value);
    }

    [Fact]
    public void NullKeyValueMatchesWithIsNull()
    {
        var change = new RowDelete(Row(("a", 1), ("b", null), ("c", "z")));

        var spec = ChangeSqlBuilder.Build(PostgreSqlDialect.Instance, Table, change);

        Assert.Equal("DELETE FROM \"public\".\"t\" WHERE \"a\" = @p0 AND \"b\" IS NULL AND \"c\" = @p1", spec.Text);
        Assert.Equal([1, "z"], spec.Parameters.Select(p => p.Value));
    }

    [Fact]
    public void InsertListsColumnsAndValues()
    {
        var spec = ChangeSqlBuilder.Build(MySqlDialect.Instance, new ObjectName(null, "t"), new RowInsert(Row(("a", 1), ("b`x", "two"))));

        Assert.Equal("INSERT INTO `t` (`a`, `b``x`) VALUES (@p0, @p1)", spec.Text);
        Assert.Equal([1, "two"], spec.Parameters.Select(p => p.Value));
    }

    [Fact]
    public void InsertWithoutValuesUsesDefaults()
    {
        var spec = ChangeSqlBuilder.Build(SqlServerDialect.Instance, new ObjectName("dbo", "t"), new RowInsert(Row()));

        Assert.Equal("INSERT INTO [dbo].[t] DEFAULT VALUES", spec.Text);
        Assert.Empty(spec.Parameters);
    }

    [Fact]
    public void DeleteFiltersByEveryKeyColumn()
    {
        var spec = ChangeSqlBuilder.Build(SqlServerDialect.Instance, new ObjectName("dbo", "t"), new RowDelete(Row(("id", 1), ("tenant", 2))));

        Assert.Equal("DELETE FROM [dbo].[t] WHERE [id] = @p0 AND [tenant] = @p1", spec.Text);
    }

    [Fact]
    public void DuckDbParametersUseDollarNames()
    {
        var spec = ChangeSqlBuilder.Build(DuckDbDialect.Instance, new ObjectName(null, "t"), new RowUpdate(Row(("id", 1)), Row(("a", 2))));

        Assert.Equal("UPDATE \"t\" SET \"a\" = $p0 WHERE \"id\" = $p1", spec.Text);
    }

    [Fact]
    public void ChangesWithoutAKeyAreRefused()
    {
        Assert.Throws<InvalidOperationException>(() => ChangeSqlBuilder.Build(PostgreSqlDialect.Instance, Table, new RowDelete(Row())));
        Assert.Throws<InvalidOperationException>(() => ChangeSqlBuilder.Build(PostgreSqlDialect.Instance, Table, new RowUpdate(Row(), Row(("a", 1)))));
    }

    [Fact]
    public void UnknownChangeTypeIsRefused() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => ChangeSqlBuilder.Build(PostgreSqlDialect.Instance, Table, new OtherChange()));

    [Fact]
    public void PreviewDoesNotConfuseP10WithP1()
    {
        var values = Enumerable.Range(0, 12).Select(i => ($"c{i}", (object?)(i * 100)));
        var change = new RowInsert(Row([.. values]));

        var preview = ChangeSqlBuilder.Preview(PostgreSqlDialect.Instance, new ObjectName(null, "t"), change);

        Assert.EndsWith("VALUES (0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100)", preview, StringComparison.Ordinal);
    }

    [Fact]
    public void PreviewWritesLiteralsPerDialect()
    {
        var change = new RowUpdate(Row(("id", 5)), Row(("name", "O'Brien"), ("active", true), ("note", null)));

        Assert.Equal(
            "UPDATE \"public\".\"t\" SET \"name\" = 'O''Brien', \"active\" = TRUE, \"note\" = NULL WHERE \"id\" = 5",
            ChangeSqlBuilder.Preview(PostgreSqlDialect.Instance, Table, change));
        Assert.Equal(
            "UPDATE [dbo].[t] SET [name] = N'O''Brien', [active] = 1, [note] = NULL WHERE [id] = 5",
            ChangeSqlBuilder.Preview(SqlServerDialect.Instance, new ObjectName("dbo", "t"), change));
    }

    [Fact]
    public void PreviewFillsPositionalParametersInOrder()
    {
        var change = new RowUpdate(Row(("id", 5)), Row(("name", "a"), ("qty", 2)));

        var preview = ChangeSqlBuilder.Preview(HanaDialect.Instance, new ObjectName("S", "T"), change);

        Assert.Equal("UPDATE \"S\".\"T\" SET \"name\" = 'a', \"qty\" = 2 WHERE \"id\" = 5", preview);
    }

    [Fact]
    public void PreviewReplacesDollarParameters() =>
        Assert.Equal(
            "INSERT INTO \"t\" (\"a\", \"b\") VALUES ('v', 2)",
            ChangeSqlBuilder.Preview(DuckDbDialect.Instance, new ObjectName(null, "t"), new RowInsert(Row(("a", "v"), ("b", 2)))));

    [Fact]
    public void PreviewDoesNotRewriteParameterNamesInsideValues()
    {
        var change = new RowUpdate(Row(("id", 5)), Row(("email", "ops@p1.example"), ("tag", "$p0 and @p1")));

        Assert.Equal(
            "UPDATE \"t\" SET \"email\" = 'ops@p1.example', \"tag\" = '$p0 and @p1' WHERE \"id\" = 5",
            ChangeSqlBuilder.Preview(PostgreSqlDialect.Instance, new ObjectName(null, "t"), change));
        Assert.Equal(
            "UPDATE \"t\" SET \"email\" = 'ops@p1.example', \"tag\" = '$p0 and @p1' WHERE \"id\" = 5",
            ChangeSqlBuilder.Preview(DuckDbDialect.Instance, new ObjectName(null, "t"), change));
    }

    [Fact]
    public void PreviewLeavesQuotedNamesAlone()
    {
        var change = new RowUpdate(Row(("id", 1)), Row(("@p1", "x")));

        Assert.Equal(
            "UPDATE \"t\" SET \"@p1\" = 'x' WHERE \"id\" = 1",
            ChangeSqlBuilder.Preview(PostgreSqlDialect.Instance, new ObjectName(null, "t"), change));
    }

    [Fact]
    public void RowCountMismatchReportsBothCounts()
    {
        var ex = new RowCountMismatchException(1, 3, "DELETE FROM t");

        Assert.Equal(1, ex.Expected);
        Assert.Equal(3, ex.Actual);
        Assert.Contains("3 rows instead of 1", ex.Message, StringComparison.Ordinal);
        Assert.Contains("DELETE FROM t", ex.Message, StringComparison.Ordinal);
    }

    private sealed record OtherChange : RowChange;
}
