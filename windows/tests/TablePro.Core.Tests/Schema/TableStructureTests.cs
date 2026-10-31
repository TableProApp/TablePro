using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Schema;

public sealed class TableStructureTests
{
    private static readonly ObjectName Orders = new("sales", "orders");

    private static TableStructure Structure() => new(
        Orders,
        [new ColumnInfo("id", "integer", false, null, true, true, 0), new ColumnInfo("total", "numeric", true, null, false, false, 1)],
        [],
        [],
        []);

    [Fact]
    public void StartsWithoutDetails()
    {
        var structure = Structure();

        Assert.Empty(structure.CheckConstraints);
        Assert.Null(structure.Partitioning);
        Assert.Empty(structure.Options);
    }

    [Fact]
    public void WithDetailsKeepsTheColumnsAndPrimaryKey()
    {
        var details = new TableDetails(
            [new CheckConstraintInfo("ck_total", "total >= 0")],
            new PartitioningInfo("RANGE", "created_at", [new PartitionInfo("orders_2025", "FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')")]),
            [new TableOption(TableOptionNames.Comment, "Customer orders")]);

        var structure = Structure().With(details);

        Assert.Equal(["id"], structure.PrimaryKey);
        Assert.Equal(2, structure.Columns.Count);
        Assert.Equal("ck_total", Assert.Single(structure.CheckConstraints).Name);
        Assert.Equal("orders_2025", Assert.Single(structure.Partitioning!.Partitions).Name);
        Assert.Equal("Customer orders", structure.Option(TableOptionNames.Comment));
    }

    [Fact]
    public void ACopyWithOtherColumnsReportsItsOwnPrimaryKey()
    {
        var original = Structure();

        var copy = original with { Columns = [new ColumnInfo("code", "text", false, null, true, false, 0), new ColumnInfo("id", "integer", false, null, false, false, 1)] };

        Assert.Equal(["code"], copy.PrimaryKey);
        Assert.Equal(["id"], original.PrimaryKey);
        Assert.Empty((original with { Columns = [] }).PrimaryKey);
    }

    [Fact]
    public void OptionLookupIgnoresCaseAndAnswersNullWhenMissing()
    {
        var structure = Structure() with { Options = [new TableOption(TableOptionNames.Engine, "InnoDB")] };

        Assert.Equal("InnoDB", structure.Option("engine"));
        Assert.Null(structure.Option(TableOptionNames.Collation));
    }

    [Fact]
    public void CheckConstraintDefaultsToValidatedWithNoColumns()
    {
        var check = new CheckConstraintInfo("ck", "a > 0");

        Assert.True(check.IsValidated);
        Assert.Empty(check.Columns);
        Assert.Equal(new CheckConstraintDefinition("ck", "a > 0"), check.ToDefinition());
    }

    [Theory]
    [InlineData("ck", "a > 0", true)]
    [InlineData("", "a > 0", false)]
    [InlineData("ck", "  ", false)]
    public void ACheckNeedsANameAndAnExpression(string name, string expression, bool complete)
    {
        Assert.Equal(complete, new CheckConstraintDefinition(name, expression).IsComplete);
    }

    [Fact]
    public void ARenameKeepsTheExpression()
    {
        var rename = new AlterCheckConstraint(new("ck_old", "a > 0"), new("ck_new", " a > 0 "));
        var rewrite = new AlterCheckConstraint(new("ck_old", "a > 0"), new("ck_new", "a > 1"));
        var same = new AlterCheckConstraint(new("ck", "a > 0"), new("ck", "a > 1"));

        Assert.True(rename.IsRenameOnly);
        Assert.False(rewrite.IsRenameOnly);
        Assert.False(same.IsRenameOnly);
    }

    [Fact]
    public void ASubpartitionNamesItsParent()
    {
        Assert.False(new PartitionInfo("p0").IsSubpartition);
        Assert.True(new PartitionInfo("p0sp0") { Parent = "p0" }.IsSubpartition);
    }

    [Fact]
    public void PartitioningReadsAsMethodAndKey()
    {
        Assert.Equal("RANGE (created_at)", new PartitioningInfo("RANGE", "created_at", []).ToString());
        Assert.Equal("HASH", new PartitioningInfo("HASH", string.Empty, []).ToString());
    }

    [Fact]
    public void DiffReturnsOnlyChangedOptions()
    {
        IReadOnlyList<TableOption> current =
        [
            new(TableOptionNames.Engine, "InnoDB"),
            new(TableOptionNames.Comment, null),
            new(TableOptionNames.RowFormat, "Dynamic"),
        ];
        var edited = new Dictionary<string, string?>
        {
            [TableOptionNames.Engine] = " InnoDB ",
            [TableOptionNames.Comment] = string.Empty,
            [TableOptionNames.RowFormat] = "COMPRESSED",
            [TableOptionNames.AutoIncrement] = "1000",
        };

        var changes = TableOptionChange.Diff(current, edited);

        Assert.Equal(2, changes.Count);
        Assert.Contains(new TableOptionChange(TableOptionNames.RowFormat, "Dynamic", "COMPRESSED"), changes);
        Assert.Contains(new TableOptionChange(TableOptionNames.AutoIncrement, null, "1000"), changes);
    }

    [Fact]
    public void ClearingAnOptionIsAChangeToNothing()
    {
        var change = Assert.Single(TableOptionChange.Diff([new TableOption(TableOptionNames.Comment, "old")], new Dictionary<string, string?> { ["comment"] = "  " }));

        Assert.Equal("old", change.Before);
        Assert.Null(change.After);
        Assert.True(change.Clears);
    }
}
