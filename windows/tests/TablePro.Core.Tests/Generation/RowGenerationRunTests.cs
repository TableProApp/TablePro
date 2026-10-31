using TablePro.Core.Connections;
using TablePro.Core.Generation;
using TablePro.Core.Schema;
using TablePro.Core.Tests.Copy;

namespace TablePro.Core.Tests.Generation;

public sealed class RowGenerationRunTests
{
    private static RowGenerationSettings Defaults(RowGenerationTable table, int rows = 10) =>
        RowGenerationDefaults.ForTable(table, new DateOnly(2026, 1, 1), 11, rows);

    [Fact]
    public void SettingsThatFitRaiseNothing()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("name", "text", RowValueClass.Text), new RowGenerationColumn("n", "int", RowValueClass.Integer)]);

        Assert.Empty(RowGenerationValidation.Issues(Defaults(table), table));
    }

    [Fact]
    public void TheRowCountStaysBetweenOneAndAMillion()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("n", "int", RowValueClass.Integer)]);

        Assert.Contains(RowGenerationValidation.Issues(Defaults(table, 0), table), i => i.Column is null);
        Assert.Contains(RowGenerationValidation.Issues(Defaults(table, RowGenerationSettings.MaximumRowCount + 1), table), i => i.Column is null);
    }

    [Fact]
    public void ARangePastTheColumnNamesItsLimits()
    {
        var column = new RowGenerationColumn("n", "smallint", RowValueClass.Integer) { IntegerMinimum = -32768, IntegerMaximum = 32767 };
        var table = new RowGenerationTable([column]);
        var settings = Defaults(table).With("n", new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = 0, IntegerMaximum = 40_000 });

        var issue = Assert.Single(RowGenerationValidation.Issues(settings, table));
        Assert.Equal("n", issue.Column);
        Assert.Contains("holds numbers from", issue.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ASequencePastTheMaximumAndAUniqueColumnWithTooFewValuesAreRefused()
    {
        var table = new RowGenerationTable(
        [
            new RowGenerationColumn("s", "tinyint", RowValueClass.Integer) { IntegerMinimum = 0, IntegerMaximum = 255 },
            new RowGenerationColumn("u", "int", RowValueClass.Integer) { IsUnique = true },
        ]);
        var settings = Defaults(table, 300)
            .With("s", new RowGeneratorSettings(RowGeneratorKind.Sequence) { IntegerMinimum = 1 })
            .With("u", new RowGeneratorSettings(RowGeneratorKind.IntegerRange) { IntegerMinimum = 1, IntegerMaximum = 10 });

        var issues = RowGenerationValidation.Issues(settings, table);

        Assert.Contains(issues, i => i.Column == "s");
        Assert.Contains(issues, i => i.Column == "u" && i.Message.Contains("only 10 different values", StringComparison.Ordinal));
    }

    [Fact]
    public void BlankListLinesEmptyPatternsAndReversedRangesAreCaught()
    {
        var table = new RowGenerationTable(
        [
            new RowGenerationColumn("a", "text", RowValueClass.Text),
            new RowGenerationColumn("b", "text", RowValueClass.Text),
            new RowGenerationColumn("c", "date", RowValueClass.Date),
            new RowGenerationColumn("d", "numeric(4,1)", RowValueClass.Decimal) { Precision = 4, Scale = 1 },
        ]);
        var settings = Defaults(table)
            .With("a", new RowGeneratorSettings(RowGeneratorKind.List) { Values = ["", ""] })
            .With("b", new RowGeneratorSettings(RowGeneratorKind.Pattern) { Pattern = string.Empty })
            .With("c", new RowGeneratorSettings(RowGeneratorKind.Date) { DateStart = new DateOnly(2025, 1, 2), DateEnd = new DateOnly(2025, 1, 1) })
            .With("d", new RowGeneratorSettings(RowGeneratorKind.DecimalRange) { DecimalScale = 2 });

        var columns = RowGenerationValidation.Issues(settings, table).Select(i => i.Column).ToArray();

        Assert.Equal(["a", "b", "c", "d"], columns);
    }

    [Fact]
    public void KeysAndUnfillableColumnsAreNamed()
    {
        var table = new RowGenerationTable(
        [
            new RowGenerationColumn("a", "int", RowValueClass.Integer) { HasDefault = true },
            new RowGenerationColumn("b", "int", RowValueClass.Integer) { HasDefault = true },
            new RowGenerationColumn("g", "geometry", RowValueClass.Unsupported) { IsNullable = false },
            new RowGenerationColumn("p", "int", RowValueClass.Integer) { IsNullable = false, Reference = new ReferenceSlot("fk", 0) },
        ])
        {
            UniqueGroups = [["a", "b"]],
            References = [new ReferenceSource("fk", "parents", ["p"], [])],
        };
        var settings = Defaults(table, 5).With("a", new RowGeneratorSettings(RowGeneratorKind.ServerDefault)).With("b", new RowGeneratorSettings(RowGeneratorKind.ServerDefault));

        var issues = RowGenerationValidation.Issues(settings, table);

        Assert.Contains(issues, i => i.Column == "g" && i.Message.Contains("No generator", StringComparison.Ordinal));
        Assert.Contains(issues, i => i.Column == "p" && i.Message.Contains("has no rows", StringComparison.Ordinal));
        Assert.Contains(issues, i => i.Column is null && i.Message.Contains("(a, b)", StringComparison.Ordinal));
    }

    [Fact]
    public void LeavingEveryColumnToTheServerIsRefused()
    {
        var table = new RowGenerationTable([new RowGenerationColumn("id", "int", RowValueClass.Integer) { Ownership = ServerOwnership.Assigned }]);

        Assert.Contains(RowGenerationValidation.Issues(Defaults(table), table), i => i.Message.StartsWith("Choose a generator", StringComparison.Ordinal));
    }

    private static FakeSession Shop()
    {
        var session = new FakeSession(DatabaseEngine.PostgreSql);
        session.AddTable("customers", [("id", "integer", typeof(int)), ("name", "text", typeof(string))], primaryKey: ["id"]);
        session.AddTable(
            "orders",
            [("id", "integer", typeof(int)), ("customer_id", "integer", typeof(int)), ("placed", "date", typeof(DateTime)), ("note", "text", typeof(string))],
            primaryKey: ["id"],
            keys: [FakeSession.Key("orders_customer_fk", "customer_id", "customers", "id")]);
        session.Insert("customers", [1, "Ann"], [2, "Bob"], [3, null]);
        session.Insert("orders", [7, 1, null, null], [9, 2, null, null]);
        return session;
    }

    [Fact]
    public async Task LoadsReferencesKeyMaximumsAndProviderTypes()
    {
        var session = Shop();

        var target = await RowGenerationLoader.LoadAsync(session, new ObjectName("public", "orders"), TestContext.Current.CancellationToken);

        var source = Assert.Single(target.Model.References);
        Assert.Equal([1, 2, 3], source.Tuples.Select(t => (int)t[0]!));
        Assert.Equal(9, target.Model.KeyMaximums["id"]);
        Assert.Equal(typeof(DateTime), target.ClrTypes["placed"]);
        Assert.True(target.NullsAreDistinct);
    }

    [Fact]
    public async Task InsertsInBatchesConvertingToTheProviderTypes()
    {
        var session = Shop();
        var table = new ObjectName("public", "orders");
        var target = await RowGenerationLoader.LoadAsync(session, table, TestContext.Current.CancellationToken);
        var settings = RowGenerationDefaults.ForTable(target.Model, new DateOnly(2026, 1, 1), 3, 25);
        var engine = new RowGenerationEngine(target.Model, settings, target.NullsAreDistinct);
        var reported = new List<int>();

        var written = await RowGenerationWriter.InsertAsync(session, target, engine, 25, new SyncProgress<int>(reported.Add), TestContext.Current.CancellationToken, batchSize: 10);

        Assert.Equal(25, written);
        Assert.Equal([10, 10, 5], session.SavedBatches);
        Assert.Equal([10, 20, 25], reported);
        var rows = session.Tables[table].Rows.Skip(2).ToArray();
        Assert.Equal(Enumerable.Range(10, 25), rows.Select(r => (int)r["id"]!));
        Assert.All(rows, r => Assert.InRange((int)r["customer_id"]!, 1, 3));
        Assert.All(rows, r => Assert.IsType<DateTime>(r["placed"]));
    }

    [Fact]
    public async Task AFailedBatchReportsTheRowsAlreadyKept()
    {
        var session = Shop();
        var table = new ObjectName("public", "orders");
        var target = await RowGenerationLoader.LoadAsync(session, table, TestContext.Current.CancellationToken);
        var engine = new RowGenerationEngine(target.Model, RowGenerationDefaults.ForTable(target.Model, new DateOnly(2026, 1, 1), 3, 30));
        session.RejectInsert = (_, values) => (int)values["id"]! == 25;

        var error = await Assert.ThrowsAsync<RowGenerationWriteException>(() =>
            RowGenerationWriter.InsertAsync(session, target, engine, 30, null, TestContext.Current.CancellationToken, batchSize: 10));

        Assert.Equal(10, error.KeptRows);
        Assert.Equal(12, session.Tables[table].Rows.Count);
    }

    [Fact]
    public async Task CancellingStopsBetweenBatches()
    {
        var session = Shop();
        var table = new ObjectName("public", "orders");
        var target = await RowGenerationLoader.LoadAsync(session, table, TestContext.Current.CancellationToken);
        var engine = new RowGenerationEngine(target.Model, RowGenerationDefaults.ForTable(target.Model, new DateOnly(2026, 1, 1), 3, 30));
        using var cancellation = new CancellationTokenSource();
        session.CancelAfterFirstBatch = cancellation;

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => RowGenerationWriter.InsertAsync(session, target, engine, 30, null, cancellation.Token, batchSize: 10));

        Assert.Equal([10], session.SavedBatches);
    }

    [Fact]
    public void BindsValuesToTheProvidersTypes()
    {
        Assert.Equal(5, RowValueBinder.ToProviderType(5L, typeof(int)));
        Assert.Equal(new DateTime(2024, 3, 1), RowValueBinder.ToProviderType(new DateOnly(2024, 3, 1), typeof(DateTime)));
        Assert.Equal(TimeSpan.FromHours(13), RowValueBinder.ToProviderType(new TimeOnly(13, 0), typeof(TimeSpan)));
        Assert.Equal(1, RowValueBinder.ToProviderType(true, typeof(int)));
        Assert.Equal("12.50", RowValueBinder.ToProviderType(12.50m, typeof(string)));
        Assert.Equal(42L, RowValueBinder.ToProviderType("42", typeof(long)));
        Assert.Equal("not a number", RowValueBinder.ToProviderType("not a number", typeof(long)));
        Assert.Equal(300L, RowValueBinder.ToProviderType(300L, typeof(byte)));
    }

    /// <summary>Reports on the calling thread, so a test reads every report as soon as the call returns.</summary>
    internal sealed class SyncProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
