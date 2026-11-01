using System.Data;
using System.Numerics;
using TablePro.Core.Data;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Results;

public sealed class ResultSetTests
{
    [Theory]
    [InlineData(typeof(int), true)]
    [InlineData(typeof(long), true)]
    [InlineData(typeof(short), true)]
    [InlineData(typeof(byte), true)]
    [InlineData(typeof(sbyte), true)]
    [InlineData(typeof(ushort), true)]
    [InlineData(typeof(uint), true)]
    [InlineData(typeof(ulong), true)]
    [InlineData(typeof(decimal), true)]
    [InlineData(typeof(double), true)]
    [InlineData(typeof(float), true)]
    [InlineData(typeof(BigInteger), true)]
    [InlineData(typeof(string), false)]
    [InlineData(typeof(bool), false)]
    [InlineData(typeof(DateTime), false)]
    [InlineData(typeof(object), false)]
    public void NumericColumnsAreDetectedByClrType(Type type, bool expected) =>
        Assert.Equal(expected, new ResultColumn("c", "t", type).IsNumeric);

    [Fact]
    public void ResultSetExposesRowsAndCells()
    {
        var set = new ResultSet(
            [new ResultColumn("Id", "int", typeof(int)), new ResultColumn("Name", "text", typeof(string))],
            [[1, "a"], [2, null]],
            isTruncated: true);

        Assert.Equal(2, set.RowCount);
        Assert.True(set.IsTruncated);
        Assert.Equal("a", set[0, 1]);
        Assert.Null(set[1, 1]);
        Assert.Equal(1, set.ColumnIndex("name"));
        Assert.Equal(0, set.ColumnIndex("ID"));
        Assert.Equal(-1, set.ColumnIndex("missing"));
    }

    [Fact]
    public void StatementResultSucceedsWithoutError()
    {
        Assert.True(new StatementResult("SELECT 1", [], 0, TimeSpan.Zero).Succeeded);
        Assert.False(new StatementResult("SELECT 1", [], -1, TimeSpan.Zero, "boom").Succeeded);
    }

    [Fact]
    public void ExecuteOptionsDefaults()
    {
        var options = new ExecuteOptions();

        Assert.Equal(10_000, options.RowLimit);
        Assert.Equal(0, options.CommandTimeoutSeconds);
        Assert.True(options.StopOnError);
    }

    [Fact]
    public async Task ReaderStopsAtTheRowLimitAndMapsNulls()
    {
        using var table = new DataTable();
        table.Columns.Add("id", typeof(int));
        table.Columns.Add("name", typeof(string));
        table.Rows.Add(1, "a");
        table.Rows.Add(2, DBNull.Value);
        table.Rows.Add(3, "c");
        using var reader = table.CreateDataReader();

        var set = await ResultSetReader.ReadAsync(reader, 2, TestContext.Current.CancellationToken);

        Assert.True(set.IsTruncated);
        Assert.Equal(2, set.RowCount);
        Assert.Equal(["id", "name"], set.Columns.Select(c => c.Name));
        Assert.Equal(typeof(int), set.Columns[0].ClrType);
        Assert.True(set.Columns[0].IsNumeric);
        Assert.Equal(2, set[1, 0]);
        Assert.Null(set[1, 1]);
    }

    [Fact]
    public async Task ReaderWithinTheLimitIsNotTruncated()
    {
        using var table = new DataTable();
        table.Columns.Add("id", typeof(int));
        table.Rows.Add(1);
        using var reader = table.CreateDataReader();

        var set = await ResultSetReader.ReadAsync(reader, 1, TestContext.Current.CancellationToken);

        Assert.False(set.IsTruncated);
        Assert.Equal(1, set.RowCount);
    }

    [Fact]
    public void SchemaHelpers()
    {
        Assert.Equal("public.t", new ObjectName("public", "t").ToString());
        Assert.Equal("t", new ObjectName(null, "t").ToString());
        Assert.True(new DatabaseObject(new ObjectName(null, "v"), ObjectKind.MaterializedView).HasRows);
        Assert.False(new DatabaseObject(new ObjectName(null, "f"), ObjectKind.Function).HasRows);

        var structure = new TableStructure(
            new ObjectName(null, "t"),
            [
                new ColumnInfo("tenant", "int", false, null, true, false, 1),
                new ColumnInfo("note", "text", true, null, false, false, 2),
                new ColumnInfo("id", "int", false, null, true, true, 3),
            ],
            [],
            [],
            []);

        Assert.Equal(["tenant", "id"], structure.PrimaryKey);
    }

    [Fact]
    public void ColumnDefinitionCopiesColumnInfo()
    {
        var info = new ColumnInfo("id", "bigint", false, "nextval()", true, true, 1, "key");

        Assert.Equal(new ColumnDefinition("id", "bigint", false, "nextval()", true, true, "key"), ColumnDefinition.From(info));
    }
}
