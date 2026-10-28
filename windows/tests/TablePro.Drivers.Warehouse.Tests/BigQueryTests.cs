using Google.Apis.Bigquery.v2.Data;
using Google.Cloud.BigQuery.V2;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Drivers.BigQuery;

namespace TablePro.Drivers.Warehouse.Tests;

public sealed class BigQueryTests
{
    private static readonly TableFieldSchema[] Schema =
    [
        new() { Name = "id", Type = "INT64", Mode = "REQUIRED" },
        new() { Name = "name", Type = "STRING", Description = "Display name" },
        new()
        {
            Name = "address",
            Type = "RECORD",
            Fields =
            [
                new() { Name = "city", Type = "STRING" },
                new() { Name = "geo", Type = "RECORD", Fields = [new() { Name = "lat", Type = "FLOAT64" }] },
            ],
        },
        new() { Name = "tags", Type = "STRING", Mode = "REPEATED" },
        new() { Name = "doc", Type = "JSON" },
        new() { Name = "amount", Type = "NUMERIC" },
    ];

    private static Dictionary<string, BigQueryField> Fields() => BigQuerySchema.Flatten(Schema).ToDictionary(f => f.Path);

    [Fact]
    public void FlattensNestedRecordsAsDottedNamesTypedJson()
    {
        var fields = BigQuerySchema.Flatten(Schema);

        Assert.Equal(["id", "name", "address", "address.city", "address.geo", "address.geo.lat", "tags", "doc", "amount"], fields.Select(f => f.Path));
        Assert.Equal(["INT64", "STRING", "JSON", "STRING", "JSON", "FLOAT64", "JSON", "JSON", "NUMERIC"], fields.Select(f => f.DisplayType));
        Assert.Equal([0, 0, 0, 1, 1, 2, 0, 0, 0], fields.Select(f => f.Depth));
        Assert.False(fields[0].IsNullable);
        Assert.Equal(["id", "name", "amount"], fields.Where(f => f.IsComparable).Select(f => f.Path));
    }

    [Fact]
    public void StructureMarksOnlyTopLevelKeyColumns()
    {
        var columns = BigQuerySchema.Columns(BigQuerySchema.Flatten(Schema), ["id", "address.city"]);

        Assert.Equal(["id"], columns.Where(c => c.IsPrimaryKey).Select(c => c.Name));
        Assert.Equal("Display name", columns[1].Comment);
        Assert.Equal(Enumerable.Range(0, columns.Count), columns.Select(c => c.Ordinal));
    }

    [Fact]
    public void RecordAndArrayValuesReadAsJson()
    {
        var record = new Dictionary<string, object> { ["city"] = "Oslo", ["geo"] = new Dictionary<string, object> { ["lat"] = 59.9 }, ["zip"] = null! };

        Assert.Equal("{\"city\":\"Oslo\",\"geo\":{\"lat\":59.9},\"zip\":null}", BigQuerySchema.GridValue(record));
        Assert.Equal("[\"a\",\"b\"]", BigQuerySchema.GridValue(new List<string> { "a", "b" }));
        Assert.Equal(12.5m, BigQuerySchema.GridValue(BigQueryNumeric.Parse("12.5")));
        Assert.Equal("12345678901234567890123456789.123456789", BigQuerySchema.GridValue(BigQueryNumeric.Parse("12345678901234567890123456789.123456789")));
        Assert.Equal(5L, BigQuerySchema.GridValue(5L));
    }

    [Fact]
    public void ResultColumnsTypeComplexFieldsAsJsonText()
    {
        var columns = BigQuerySchema.ResultColumns(new TableSchema { Fields = Schema });

        Assert.Equal(["INT64", "STRING", "JSON", "JSON", "JSON", "NUMERIC"], columns.Select(c => c.DataType));
        Assert.Equal([typeof(long), typeof(string), typeof(string), typeof(string), typeof(string), typeof(decimal)], columns.Select(c => c.ClrType));
    }

    [Theory]
    [InlineData(500L, 1000L, true)]
    [InlineData(1000L, 1000L, true)]
    [InlineData(1001L, 1000L, false)]
    public void DryRunRefusesAboveTheLimit(long estimate, long limit, bool allowed)
    {
        var check = BigQueryCost.Evaluate(estimate, limit);

        Assert.Equal(allowed, check.Allowed);
        Assert.StartsWith(allowed ? "Estimated scan:" : "Not run:", check.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void DryRunMessagesNameTheSizes()
    {
        Assert.Equal("Not run: the query would scan 12 GB, over the maxBytesBilled limit of 10 GB.", BigQueryCost.Evaluate(12L << 30, 10L << 30).Message);
        Assert.Equal("Estimated scan: 1.5 MB (limit 1 GB).", BigQueryCost.Evaluate(1536L * 1024, 1L << 30).Message);
        Assert.Equal("Estimated scan: 0 B.", BigQueryCost.Evaluate(0, null).Message);
    }

    [Theory]
    [InlineData("1000000000", 1_000_000_000L)]
    [InlineData("10GB", 10L << 30)]
    [InlineData("500 mb", 500L << 20)]
    [InlineData("1_000", 1000L)]
    [InlineData("1.5 KB", 1536L)]
    public void ParsesByteLimits(string text, long expected)
    {
        Assert.Equal(expected, BigQueryCost.ParseBytes(text));
    }

    [Theory]
    [InlineData("")]
    [InlineData("lots")]
    [InlineData("10 parsecs")]
    public void RejectsWhatIsNotAByteCount(string text)
    {
        Assert.Null(BigQueryCost.ParseBytes(text));
    }

    [Fact]
    public void SettingsReadTheProjectLimitAndKeys()
    {
        var settings = BigQuerySettings.From(Profiles.Request(
            DatabaseEngine.BigQuery,
            host: "localhost",
            database: "my-project",
            filePath: @"C:\keys\sa.json",
            options: new Dictionary<string, string>
            {
                ["maxBytesBilled"] = "10GB",
                ["location"] = "EU",
                ["keyColumns"] = "sales.orders=order_id, line; id",
            }));

        Assert.Equal("my-project", settings.ProjectId);
        Assert.Equal(@"C:\keys\sa.json", settings.CredentialsFile);
        Assert.Equal("EU", settings.Location);
        Assert.Equal(10L << 30, settings.MaxBytesBilled);
        Assert.Equal(["order_id", "line"], settings.KeyColumnsFor(new ObjectName("sales", "orders")));
        Assert.Equal(["id"], settings.KeyColumnsFor(new ObjectName("sales", "customers")));
    }

    [Fact]
    public void ProjectFallsBackToTheHostAndIsRequired()
    {
        Assert.Equal("host-project", BigQuerySettings.From(Profiles.Request(DatabaseEngine.BigQuery, host: "host-project", database: null)).ProjectId);
        Assert.Throws<ArgumentException>(() => BigQuerySettings.From(Profiles.Request(DatabaseEngine.BigQuery, host: "localhost", database: null)));
        Assert.Throws<ArgumentException>(() => BigQuerySettings.From(Profiles.Request(
            DatabaseEngine.BigQuery, options: new Dictionary<string, string> { ["maxBytesBilled"] = "plenty" })));
        Assert.Null(BigQuerySettings.From(Profiles.Request(DatabaseEngine.BigQuery)).KeyColumnsFor(new ObjectName("d", "t")));
    }

    [Fact]
    public void BrowseBindsTypedNamedParametersAndEscapesLike()
    {
        var filter = new BrowseFilter([
            new FilterRule("id", FilterOperator.Equals, "42"),
            new FilterRule("name", FilterOperator.Contains, "50%_off"),
            new FilterRule(null, FilterOperator.Contains, "x"),
        ])
        { SearchColumns = ["name", "address", "address.city"] };

        var statement = BigQuerySql.Browse("`p`.`d`.`t`", new BrowseRequest(new ObjectName("d", "t"), filter, [new SortColumn("id", false)], 100, 50), Fields());

        Assert.Equal(
            "SELECT * FROM `p`.`d`.`t` WHERE `id` = @p0 AND LOWER(`name`) LIKE LOWER(@p1) AND (LOWER(`name`) LIKE LOWER(@p2) OR LOWER(TO_JSON_STRING(`address`)) LIKE LOWER(@p2)) "
            + "ORDER BY `id` ASC LIMIT @__limit OFFSET @__offset",
            statement.Sql);
        Assert.Equal(BigQueryDbType.Int64, statement.Parameters[0].Type);
        Assert.Equal(42L, statement.Parameters[0].Value);
        Assert.Equal("%50\\%\\_off%", statement.Parameters[1].Value);
        Assert.Equal(50L, statement.Parameters.Single(p => p.Name == "__limit").Value);
        Assert.Equal(100L, statement.Parameters.Single(p => p.Name == "__offset").Value);
    }

    [Fact]
    public void AFilterValueThatIsNotOfTheColumnTypeIsRefused()
    {
        var filter = new BrowseFilter([new FilterRule("id", FilterOperator.Equals, "forty-two")]);

        Assert.Throws<FormatException>(() => BigQuerySql.Count("`t`", filter, Fields()));
    }

    [Fact]
    public void SaveRunsOneTransactionalScriptThatChecksEachKeyedRow()
    {
        var changes = new RowChange[]
        {
            new RowUpdate(new Dictionary<string, object?> { ["id"] = 7L, ["doc"] = "{}", ["tags"] = "[]", ["name"] = null }, new Dictionary<string, object?> { ["amount"] = "9.99" }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = 8L, ["name"] = "new" }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = 9L }),
        };

        var statement = BigQuerySql.Save("`p`.`d`.`t`", changes, Fields());

        Assert.Equal(
            "BEGIN\n  BEGIN TRANSACTION;\n"
            + "  UPDATE `p`.`d`.`t` SET `amount` = @p0 WHERE `id` = @p1 AND `name` IS NULL;\n"
            + "  IF @@row_count <> 1 THEN RAISE USING MESSAGE = FORMAT('TABLEPRO_ROWCOUNT %d %d', 0, @@row_count); END IF;\n"
            + "  INSERT INTO `p`.`d`.`t` (`id`, `name`) VALUES (@p2, @p3);\n"
            + "  DELETE FROM `p`.`d`.`t` WHERE `id` = @p4;\n"
            + "  IF @@row_count <> 1 THEN RAISE USING MESSAGE = FORMAT('TABLEPRO_ROWCOUNT %d %d', 2, @@row_count); END IF;\n"
            + "  COMMIT TRANSACTION;\nEXCEPTION WHEN ERROR THEN\n  ROLLBACK TRANSACTION;\n  RAISE USING MESSAGE = @@error.message;\nEND;",
            statement.Sql);
        Assert.Equal(BigQueryDbType.Numeric, statement.Parameters[0].Type);
        Assert.Equal(BigQueryDbType.Int64, statement.Parameters[1].Type);
    }

    [Fact]
    public void ARowWithNoComparableColumnCannotBeSaved()
    {
        var change = new RowDelete(new Dictionary<string, object?> { ["doc"] = "{}", ["tags"] = "[]" });

        Assert.Throws<InvalidOperationException>(() => BigQuerySql.Save("`t`", [change], Fields()));
    }

    [Fact]
    public void ReadsTheRowCheckBackFromTheError()
    {
        Assert.Equal((2, 3), BigQuerySql.ParseRowCountFailure("Query error: TABLEPRO_ROWCOUNT 2 3 at [5:3]"));
        Assert.Equal((0, 0), BigQuerySql.ParseRowCountFailure("TABLEPRO_ROWCOUNT 0 0"));
        Assert.Null(BigQuerySql.ParseRowCountFailure("Syntax error"));
    }

    [Fact]
    public void QuotesWithBackslashEscapes()
    {
        Assert.Equal("`my-project`.`d`.`we\\`ird`", BigQuerySql.Table("my-project", "d", "we`ird"));
    }
}
