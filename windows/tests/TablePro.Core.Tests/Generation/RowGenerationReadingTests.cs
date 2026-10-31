using TablePro.Core.Connections;
using TablePro.Core.Generation;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Generation;

public sealed class RowGenerationReadingTests
{
    private static readonly DateOnly Today = new(2026, 10, 29);

    internal static RowGenerationColumn Text(string name, int? length = null) => new(name, "varchar", RowValueClass.Text) { MaxLength = length };

    internal static RowGenerationColumn Integer(string name) => new(name, "bigint", RowValueClass.Integer);

    [Theory]
    [InlineData("email", RowGeneratorKind.Email)]
    [InlineData("customerEmail", RowGeneratorKind.Email)]
    [InlineData("first_name", RowGeneratorKind.FirstName)]
    [InlineData("LastName", RowGeneratorKind.LastName)]
    [InlineData("surname", RowGeneratorKind.LastName)]
    [InlineData("mobile_phone", RowGeneratorKind.Phone)]
    [InlineData("street_address", RowGeneratorKind.StreetAddress)]
    [InlineData("city", RowGeneratorKind.City)]
    [InlineData("country", RowGeneratorKind.Country)]
    [InlineData("zip", RowGeneratorKind.Pattern)]
    [InlineData("name", RowGeneratorKind.FullName)]
    [InlineData("customer_name", RowGeneratorKind.FullName)]
    [InlineData("product_name", RowGeneratorKind.Text)]
    [InlineData("guid", RowGeneratorKind.Uuid)]
    [InlineData("description", RowGeneratorKind.Text)]
    public void ATextColumnsGeneratorFollowsItsName(string name, RowGeneratorKind kind) =>
        Assert.Equal(kind, RowGenerationDefaults.Kind(Text(name)));

    [Fact]
    public void TheTypeDecidesBeforeTheName()
    {
        Assert.Equal(RowGeneratorKind.IntegerRange, RowGenerationDefaults.Kind(Integer("email")));
        Assert.Equal(RowGeneratorKind.Boolean, RowGenerationDefaults.Kind(new RowGenerationColumn("name", "boolean", RowValueClass.Boolean)));
        Assert.Equal(RowGeneratorKind.DateTime, RowGenerationDefaults.Kind(new RowGenerationColumn("city", "timestamp", RowValueClass.Timestamp)));
        Assert.Equal(RowGeneratorKind.Sequence, RowGenerationDefaults.Kind(Integer("id") with { IsUnique = true }));
    }

    [Fact]
    public void ServerColumnsAndForeignKeysStartWhereTheyShould()
    {
        Assert.Equal(RowGeneratorKind.ServerDefault, RowGenerationDefaults.Kind(Integer("id") with { Ownership = ServerOwnership.Assigned }));
        Assert.Equal(RowGeneratorKind.Reference, RowGenerationDefaults.Kind(Integer("customer_id") with { Reference = new ReferenceSlot("fk", 0) }));
        Assert.Equal([RowGeneratorKind.ServerDefault], (Integer("v") with { Ownership = ServerOwnership.Computed }).AvailableKinds);
    }

    [Fact]
    public void AKeySequenceStartsPastTheLargestValueAndRangesStayInsideTheColumn()
    {
        var key = Integer("id") with { IsUnique = true, IntegerMinimum = -128, IntegerMaximum = 127 };
        var age = Integer("age") with { IntegerMinimum = 0, IntegerMaximum = 50 };
        var table = new RowGenerationTable([key, age]) { KeyMaximums = new Dictionary<string, long> { ["id"] = 41 } };

        var keySettings = RowGenerationDefaults.Settings(key, table, Today);
        var ageSettings = RowGenerationDefaults.Settings(age, table, Today);

        Assert.Equal(42, keySettings.IntegerMinimum);
        Assert.Equal(127, keySettings.IntegerMaximum);
        Assert.Equal((18, 50), (ageSettings.IntegerMinimum, ageSettings.IntegerMaximum));
        Assert.Equal(new DateOnly(2022, 1, 1), keySettings.DateStart);
        Assert.Equal(new DateOnly(2026, 12, 31), keySettings.DateEnd);
    }

    [Fact]
    public void AnEnumColumnStartsWithItsLabelsAndTextFitsItsLength()
    {
        var status = new RowGenerationColumn("status", "enum", RowValueClass.Enumeration) { Labels = ["new", "paid"] };
        var title = Text("title", 12);
        var table = new RowGenerationTable([status, title]);

        Assert.Equal(["new", "paid"], RowGenerationDefaults.Settings(status, table, Today).Values);
        var text = RowGenerationDefaults.Settings(title, table, Today);
        Assert.Equal((10, 12), (text.MinLength, text.MaxLength));
    }

    [Theory]
    [InlineData("customerEmail", new[] { "customer", "email" })]
    [InlineData("customer_email", new[] { "customer", "email" })]
    [InlineData("CUSTOMER-EMAIL", new[] { "customer", "email" })]
    [InlineData("address2Line", new[] { "address2", "line" })]
    public void ANameSplitsIntoWordsHoweverItIsWritten(string name, string[] tokens) => Assert.Equal(tokens, RowGenerationDefaults.NameTokens(name));

    private static TableStructure Structure(ColumnInfo[] columns, IndexInfo[]? indexes = null, ForeignKeyInfo[]? keys = null) =>
        new(new ObjectName("public", "t"), columns, indexes ?? [], keys ?? [], []);

    private static ColumnInfo Column(string name, string type, bool primaryKey = false, bool identity = false, string? defaultValue = null, bool nullable = true, int ordinal = 0) =>
        new(name, type, nullable, defaultValue, primaryKey, identity, ordinal);

    [Fact]
    public void ReadsIntegerWidthsUnsignedBooleansAndEnumsFromTheDeclaredType()
    {
        var (columns, _, _) = RowGenerationColumnReader.Read(
            Structure(
            [
                Column("a", "tinyint(1)", ordinal: 0),
                Column("b", "smallint unsigned", ordinal: 1),
                Column("c", "int", ordinal: 2),
                Column("d", "enum('x','y''z')", ordinal: 3),
                Column("e", "varchar(40)", ordinal: 4),
                Column("f", "decimal(6,2)", ordinal: 5),
                Column("g", "blob", nullable: false, ordinal: 6),
            ]),
            DatabaseEngine.MySql);

        Assert.Equal(RowValueClass.Boolean, columns[0].ValueClass);
        Assert.Equal((0, 65_535), (columns[1].IntegerMinimum, columns[1].IntegerMaximum));
        Assert.Equal((int.MinValue, int.MaxValue), ((int)columns[2].IntegerMinimum, (int)columns[2].IntegerMaximum));
        Assert.Equal(["x", "y'z"], columns[3].Labels);
        Assert.Equal(40, columns[4].MaxLength);
        Assert.Equal((6, 2), (columns[5].Precision, columns[5].Scale));
        Assert.Equal(RowValueClass.Unsupported, columns[6].ValueClass);
        Assert.Empty(columns[6].AvailableKinds);
    }

    [Fact]
    public void TellsServerFilledColumnsFromComputedOnes()
    {
        var pg = RowGenerationColumnReader.Read(Structure([Column("id", "integer", true, defaultValue: "nextval('t_id_seq'::regclass)"), Column("n", "integer", identity: true, ordinal: 1)]), DatabaseEngine.PostgreSql).Columns;
        var mssql = RowGenerationColumnReader.Read(Structure([Column("id", "int", true, identity: true), Column("v", "rowversion", ordinal: 1)]), DatabaseEngine.SqlServer).Columns;
        var sqlite = RowGenerationColumnReader.Read(Structure([Column("id", "INTEGER", true), Column("x", "TEXT", ordinal: 1, defaultValue: "NULL")]), DatabaseEngine.Sqlite).Columns;

        Assert.Equal([ServerOwnership.Assigned, ServerOwnership.Assigned], pg.Select(c => c.Ownership));
        Assert.Equal([ServerOwnership.Computed, ServerOwnership.Computed], mssql.Select(c => c.Ownership));
        Assert.Equal(ServerOwnership.Assigned, sqlite[0].Ownership);
        Assert.False(sqlite[1].HasDefault);
    }

    [Fact]
    public void UniqueIndexesMakeAColumnUniqueAloneOrAKeyOfSeveral()
    {
        var (columns, groups, _) = RowGenerationColumnReader.Read(
            Structure(
                [Column("a", "int"), Column("b", "int", ordinal: 1), Column("c", "int", ordinal: 2)],
                [new IndexInfo("u_a", ["a"], true, false), new IndexInfo("u_bc", ["b", "c"], true, false), new IndexInfo("u_cb", ["c", "b"], true, false), new IndexInfo("ix", ["c"], false, false)]),
            DatabaseEngine.PostgreSql);

        Assert.True(columns[0].IsUnique);
        Assert.False(columns[2].IsUnique);
        Assert.Equal(["b", "c"], Assert.Single(groups));
    }

    [Fact]
    public void AForeignKeyOverTwoColumnsIsOneSourceInKeyOrder()
    {
        var (columns, _, references) = RowGenerationColumnReader.Read(
            Structure(
                [Column("line", "int"), Column("order_id", "int", ordinal: 1)],
                keys: [new ForeignKeyInfo("fk_line", ["order_id", "line"], new ObjectName("public", "lines"), ["order_id", "line"])]),
            DatabaseEngine.PostgreSql);

        var request = Assert.Single(references);
        Assert.Equal(["order_id", "line"], request.Columns);
        Assert.Equal(new ReferenceSlot(request.Id, 1), columns[0].Reference);
        Assert.Equal(new ReferenceSlot(request.Id, 0), columns[1].Reference);
    }
}
