using TablePro.Core.Import;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Import;

public sealed class ImportRowWritingTests
{
    private static readonly ObjectName Users = new("app", "users");

    private static ColumnInfo Column(string name, bool primary = false, bool identity = false) =>
        new(name, "int", true, null, primary, identity, 0);

    [Fact]
    public void OffersThePrimaryKeyThenEachUniqueIndexOverOtherColumns()
    {
        var columns = new[] { Column("id", primary: true), Column("email"), Column("tenant"), Column("code") };
        var indexes = new[]
        {
            new IndexInfo("pk_users", ["id"], IsUnique: true, IsPrimary: true),
            new IndexInfo("ux_email", ["EMAIL"], IsUnique: true, IsPrimary: false),
            new IndexInfo("ux_id_again", ["id"], IsUnique: true, IsPrimary: false),
            new IndexInfo("ux_tenant_code", ["tenant", "code"], IsUnique: true, IsPrimary: false),
            new IndexInfo("ix_code", ["code"], IsUnique: false, IsPrimary: false),
            new IndexInfo("ux_lower_email", ["lower(email)"], IsUnique: true, IsPrimary: false),
        };

        var keys = ImportMatchKey.Options(columns, indexes);

        Assert.Equal(3, keys.Count);
        Assert.True(keys[0].IsPrimaryKey);
        Assert.Equal(["id"], keys[0].Columns);
        Assert.Equal(new ImportMatchKey("ux_email", ["email"]), keys[1]);
        Assert.Equal(new ImportMatchKey("ux_tenant_code", ["tenant", "code"]), keys[2]);
    }

    [Fact]
    public void FallsBackToTheFlaggedPrimaryKeyColumnsWhenNoIndexIsMarkedPrimary()
    {
        var keys = ImportMatchKey.Options([Column("a", primary: true), Column("b", primary: true)], []);

        Assert.Equal([new ImportMatchKey(null, ["a", "b"])], keys);
    }

    [Fact]
    public void ACaseFoldedSpellingTwoColumnsShareNamesNeither()
    {
        var keys = ImportMatchKey.Options([Column("ID"), Column("id")], [new IndexInfo("ux", ["Id"], IsUnique: true, IsPrimary: false)]);

        Assert.Empty(keys);
    }

    [Fact]
    public void InsertNeedsNoKey() => Assert.Null(ImportRowWritingProblem.Of(ImportWriteMode.Insert, null, ["name"]));

    [Fact]
    public void MatchingModesNeedAKeyWhoseColumnsAreAllMapped()
    {
        var key = new ImportMatchKey(null, ["tenant", "code"]);

        Assert.Equal(ImportRowWritingProblemKind.NoKey, ImportRowWritingProblem.Of(ImportWriteMode.Upsert, null, ["name"])!.Kind);
        var unmapped = ImportRowWritingProblem.Of(ImportWriteMode.InsertSkippingExisting, key, ["TENANT", "name"])!;
        Assert.Equal(ImportRowWritingProblemKind.UnmappedKeyColumns, unmapped.Kind);
        Assert.Equal(["code"], unmapped.Columns);
        Assert.Null(ImportRowWritingProblem.Of(ImportWriteMode.InsertSkippingExisting, key, ["tenant", "code"]));
    }

    [Theory]
    [InlineData(ImportWriteMode.Update)]
    [InlineData(ImportWriteMode.Upsert)]
    public void UpdatingModesNeedAColumnOutsideTheKey(ImportWriteMode mode)
    {
        var key = new ImportMatchKey(null, ["id"]);

        Assert.Equal(ImportRowWritingProblemKind.NothingToUpdate, ImportRowWritingProblem.Of(mode, key, ["id"])!.Kind);
        Assert.Null(ImportRowWritingProblem.Of(mode, key, ["id", "name"]));
    }

    [Fact]
    public void RowWritingKeepsIdentityColumnsOutOfUpdates()
    {
        var mapping = new ImportMapping(
            [new ImportField("id", null, ImportFieldType.Integer), new ImportField("serial", null, ImportFieldType.Integer)],
            [new ImportTargetColumn("id", "int", typeof(long)), new ImportTargetColumn("serial", "int", typeof(long), IsIdentity: true)]);

        var writing = mapping.RowWriting(ImportWriteMode.Upsert, new ImportMatchKey(null, ["id"]));

        Assert.Equal(["id"], writing.KeyColumns);
        Assert.Equal(["serial"], writing.KeptColumns);
        Assert.Same(ImportRowWriting.Insert, mapping.RowWriting(ImportWriteMode.Insert, new ImportMatchKey(null, ["id"])));
    }

    public static TheoryData<SqlDialect, string> ProbeSql => new()
    {
        { PostgreSqlDialect.Instance, """SELECT 0, COUNT(*) FROM "app"."users" WHERE "tenant" = @p0 AND "code" = @p1 UNION ALL SELECT 1, COUNT(*) FROM "app"."users" WHERE "tenant" = @p2 AND "code" = @p3""" },
        { MySqlDialect.Instance, "SELECT 0, COUNT(*) FROM `app`.`users` WHERE `tenant` = @p0 AND `code` = @p1 UNION ALL SELECT 1, COUNT(*) FROM `app`.`users` WHERE `tenant` = @p2 AND `code` = @p3" },
        { SqlServerDialect.Instance, "SELECT 0, COUNT(*) FROM [app].[users] WHERE [tenant] = @p0 AND [code] = @p1 UNION ALL SELECT 1, COUNT(*) FROM [app].[users] WHERE [tenant] = @p2 AND [code] = @p3" },
        { SqliteDialect.Instance, """SELECT 0, COUNT(*) FROM "app"."users" WHERE "tenant" = @p0 AND "code" = @p1 UNION ALL SELECT 1, COUNT(*) FROM "app"."users" WHERE "tenant" = @p2 AND "code" = @p3""" },
        { OracleDialect.Instance, """SELECT 0, COUNT(*) FROM "app"."users" WHERE "tenant" = :p0 AND "code" = :p1 UNION ALL SELECT 1, COUNT(*) FROM "app"."users" WHERE "tenant" = :p2 AND "code" = :p3""" },
    };

    [Theory]
    [MemberData(nameof(ProbeSql))]
    public void ProbeCountsEachKeyWithEveryValueBound(SqlDialect dialect, string expected)
    {
        var spec = ImportKeyMatchSql.Build(dialect, Users, ["tenant", "code"], [[1L, "a'b"], [2L, null]]);

        Assert.Equal(expected, spec.Text);
        Assert.Equal([1L, "a'b", 2L, null], spec.Parameters.Select(p => p.Value));
        Assert.DoesNotContain("a'b", spec.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void ProbeQuotesNamesThatHoldTheQuoteCharacter()
    {
        var spec = ImportKeyMatchSql.Build(PostgreSqlDialect.Instance, new ObjectName(null, "we\"ird"), ["k\"ey"], [[1]]);

        Assert.Equal("""SELECT 0, COUNT(*) FROM "we""ird" WHERE "k""ey" = @p0""", spec.Text);
    }

    [Fact]
    public void ProbeRefusesAKeyOfTheWrongWidth() =>
        Assert.Throws<ArgumentException>(() => ImportKeyMatchSql.Build(SqliteDialect.Instance, Users, ["a", "b"], [[1]]));

    [Fact]
    public void ProbesStayUnderTheEnginesParameterLimit()
    {
        Assert.Equal(ImportKeyMatchSql.KeysPerProbe, ImportKeyMatchSql.KeysPerStatement(PostgreSqlDialect.Instance, 3));
        Assert.Equal(2_100 / 30, ImportKeyMatchSql.KeysPerStatement(SqlServerDialect.Instance, 30));
        Assert.Equal(1, ImportKeyMatchSql.KeysPerStatement(SqlServerDialect.Instance, 5_000));
    }

    [Fact]
    public void ReadsCountsBackInKeyOrderWhateverOrderTheServerReturns()
    {
        var counts = ImportKeyMatchSql.ReadCounts([(2L, 0L), (0, 1), ("1", 3m)], 3);

        Assert.Equal([1L, 3L, 0L], counts);
        Assert.Throws<InvalidOperationException>(() => ImportKeyMatchSql.ReadCounts([(0L, 1L)], 2));
    }

    [Fact]
    public void FoldsKeysTheDatabaseMightTakeAsOne()
    {
        Assert.Equal(RowImporter.FoldedKey(["Ann", 1L]), RowImporter.FoldedKey([" ANN ", 1.0]));
        Assert.Equal(RowImporter.FoldedKey(["caf\xe9"]), RowImporter.FoldedKey(["CAFE"]));
        Assert.Equal(RowImporter.FoldedKey(["0.10"]), RowImporter.FoldedKey([0.1]));
        Assert.NotEqual(RowImporter.FoldedKey(["a"]), RowImporter.FoldedKey(["b"]));
        Assert.Null(RowImporter.FoldedKey(["a", null]));
    }
}
