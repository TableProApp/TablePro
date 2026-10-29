using TablePro.Core.Drivers;
using TablePro.Core.Import;
using TablePro.Core.Schema;
using TablePro.Core.Tests.Compare;

namespace TablePro.Core.Tests.Import;

/// <summary>"Delete existing rows first" is refused rather than run where the table could be left empty and half filled.</summary>
public sealed class DeleteExistingRowsTests
{
    private static readonly ObjectName Users = new(null, "users");

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static ImportRowBuilder Builder() => new(new Dictionary<string, string> { ["id"] = "id" }, new Dictionary<string, Type> { ["id"] = typeof(long) });

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> OneRecord()
    {
        await Task.Yield();
        yield return new Dictionary<string, object?> { ["id"] = 1L };
    }

    [Fact]
    public async Task ASessionWithoutCrossTableTransactionsIsRefusedAndKeepsItsRows()
    {
        var table = new InMemoryTableSession(InMemoryTableSession.Table("users", ["id"], "id"), [[7L]]);
        var session = new InMemoryDatabaseSession(table);

        Assert.Null(ChangeTransactions.For(session));
        Assert.False(RowImporter.CanDeleteExistingRows(session));
        await Assert.ThrowsAsync<NotSupportedException>(() => RowImporter.ImportAsync(session, Users, OneRecord(), Builder(), ImportRowWriting.ReplaceRows, null, Token));
        Assert.Single(table.Rows);
        Assert.Empty(session.SavedTables);
    }

    [Fact]
    public async Task ASessionWithoutTransactionsImportsBatchByBatch()
    {
        var table = new InMemoryTableSession(InMemoryTableSession.Table("users", ["id"], "id"), []);
        var session = new InMemoryDatabaseSession(table);

        var result = await RowImporter.ImportAsync(session, Users, Ids(RowImporter.BatchSize + 1), Builder(), ImportRowWriting.Insert, null, Token);

        Assert.False(RowImporter.CanImportInOneTransaction(session));
        Assert.False(RowImporter.RunsInOneTransaction(session, ImportRowWriting.Insert));
        Assert.Equal(RowImporter.BatchSize + 1, result.Inserted);
        Assert.Equal(["users", "users"], session.SavedTables);
    }

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> Ids(int count)
    {
        for (var i = 0; i < count; i++)
        {
            await Task.Yield();
            yield return new Dictionary<string, object?> { ["id"] = (long)i };
        }
    }
}
