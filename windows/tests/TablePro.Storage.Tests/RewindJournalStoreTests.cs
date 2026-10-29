using System.Globalization;
using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;
using TablePro.Storage.Rewind;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Tests;

public sealed class RewindJournalStoreTests : IDisposable
{
    private static readonly Guid Connection = Guid.NewGuid();
    private readonly TempDirectory _temp = new();
    private readonly InMemorySecretStore _secrets = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    private RewindJournalStore Store(RewindRetention? retention = null) => new(_temp.Paths, _secrets, retention);

    private static RewindRecord Record(string table = "users", DateTimeOffset? at = null, string secret = "ann@example.com") => new(
        Guid.NewGuid(), Connection, DatabaseEngine.PostgreSql, "app", new ObjectName("public", table), at ?? DateTimeOffset.UtcNow,
        ["id", "email"], ["id"],
        [new RewindOperation(RewindOperationKind.Update, [1, secret], [1, "changed"], ["email"])]);

    [Fact]
    public async Task RecordsListAndOpen()
    {
        using var store = Store();
        var record = Record();

        await store.RecordAsync(record, Token);

        var entry = Assert.Single(await store.ListAsync(Connection, new ObjectName("public", "users"), cancellationToken: Token));
        Assert.Equal(record.Id, entry.Id);
        Assert.Equal("1 edited", entry.Summary);
        Assert.Equal(1, entry.ReversibleCount);
        var opened = await store.GetAsync(record.Id, Token);
        Assert.Equal("ann@example.com", opened!.Operations[0].Before![1]);
    }

    [Fact]
    public async Task RowDataIsEncryptedOnDisk()
    {
        using var store = Store();
        await store.RecordAsync(Record(secret: "very-secret-value"), Token);
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();

        var bytes = await File.ReadAllBytesAsync(_temp.File("rewind.db"), Token);
        var wal = File.Exists(_temp.File("rewind.db-wal")) ? await File.ReadAllBytesAsync(_temp.File("rewind.db-wal"), Token) : [];

        Assert.DoesNotContain("very-secret-value", System.Text.Encoding.UTF8.GetString([.. bytes, .. wal]), StringComparison.Ordinal);
        Assert.NotNull(_secrets.Get(RewindJournalStore.KeySecret));
    }

    [Fact]
    public async Task ClearingDropsRecordsAndTheKey()
    {
        using var store = Store();
        await store.RecordAsync(Record(), Token);

        await store.ClearAsync(Token);

        Assert.Empty(await store.ListAsync(Connection, cancellationToken: Token));
        Assert.Null(_secrets.Get(RewindJournalStore.KeySecret));
    }

    [Fact]
    public async Task LostKeyMakesRecordsUnreadableRatherThanThrowing()
    {
        using var store = Store();
        var record = Record();
        await store.RecordAsync(record, Token);

        _secrets.Delete(RewindJournalStore.KeySecret);

        Assert.Null(await store.GetAsync(record.Id, Token));
    }

    [Fact]
    public async Task ListFiltersByTableAndOrdersNewestFirst()
    {
        using var store = Store();
        var older = Record(at: DateTimeOffset.UtcNow.AddMinutes(-5));
        var newer = Record(at: DateTimeOffset.UtcNow);
        await store.RecordAsync(older, Token);
        await store.RecordAsync(newer, Token);
        await store.RecordAsync(Record("orders"), Token);

        var entries = await store.ListAsync(Connection, new ObjectName("public", "users"), cancellationToken: Token);

        Assert.Equal([newer.Id, older.Id], entries.Select(e => e.Id));
        Assert.Equal(3, (await store.ListAsync(Connection, cancellationToken: Token)).Count);
        Assert.Empty(await store.ListAsync(Guid.NewGuid(), cancellationToken: Token));
    }

    [Fact]
    public async Task RetentionDropsOldAndDeepRecords()
    {
        using var store = Store(new RewindRetention(TimeSpan.FromDays(7), MaxPerTable: 2));
        await store.RecordAsync(Record(at: DateTimeOffset.UtcNow.AddDays(-8)), Token);
        for (var i = 0; i < 3; i++)
        {
            await store.RecordAsync(Record(at: DateTimeOffset.UtcNow.AddSeconds(i)), Token);
        }

        Assert.Equal(2, (await store.ListAsync(Connection, cancellationToken: Token)).Count);
    }

    [Fact]
    public async Task ByteBudgetKeepsTheNewestEvenWhenItAloneIsOver()
    {
        using var store = Store(new RewindRetention(TimeSpan.FromDays(7), MaxBytes: 10));
        await store.RecordAsync(Record(at: DateTimeOffset.UtcNow.AddSeconds(-1)), Token);
        var newest = Record();
        await store.RecordAsync(newest, Token);

        Assert.Equal(newest.Id, Assert.Single(await store.ListAsync(Connection, cancellationToken: Token)).Id);
    }

    [Fact]
    public async Task MarksRestoredAndDeletes()
    {
        using var store = Store();
        var record = Record();
        await store.RecordAsync(record, Token);
        var when = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

        await store.MarkRestoredAsync(record.Id, when, Token);
        Assert.Equal(when, Assert.Single(await store.ListAsync(Connection, cancellationToken: Token)).RestoredAt);

        Assert.True(await store.DeleteAsync(record.Id, Token));
        Assert.False(await store.DeleteAsync(record.Id, Token));
    }

    [Fact]
    public async Task TheSummaryIsWordedWhenShownNotWhenSaved()
    {
        using var store = Store();
        await store.RecordAsync(Record(), Token);
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");

            var entry = Assert.Single(await store.ListAsync(Connection, cancellationToken: Token));

            Assert.Equal(new RewindCounts(1, 0, 0), entry.Counts);
            Assert.Equal("1 modifiée", entry.Summary);
            Assert.Equal("1 edited", entry.SavedSummary);
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }

    [Fact]
    public async Task AJournalFromBeforeCountsShowsItsSavedText()
    {
        // The table as builds that stored only the finished summary created it, holding one of their rows.
        using (var connection = new SqliteConnection($"Data Source={_temp.File("rewind.db")};Pooling=False"))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = """
                CREATE TABLE rewind (
                    id TEXT PRIMARY KEY NOT NULL, connection_id TEXT NOT NULL, database_name TEXT, schema_name TEXT,
                    table_name TEXT NOT NULL, engine TEXT NOT NULL, captured_at INTEGER NOT NULL,
                    operation_count INTEGER NOT NULL, reversible_count INTEGER NOT NULL, summary TEXT NOT NULL,
                    restores_id TEXT, restored_at INTEGER, byte_count INTEGER NOT NULL, payload BLOB NOT NULL);
                INSERT INTO rewind VALUES ($id, $connection, 'app', 'public', 'users', 'PostgreSql', $at, 2, 2, '2 edited', NULL, NULL, 1, x'00');
                """;
            command.Parameters.AddWithValue("$id", Guid.NewGuid().ToString("D"));
            command.Parameters.AddWithValue("$connection", Connection.ToString("D"));
            command.Parameters.AddWithValue("$at", DateTimeOffset.UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds());
            command.ExecuteNonQuery();
        }

        using var store = Store();
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");

            var old = Assert.Single(await store.ListAsync(Connection, cancellationToken: Token));
            Assert.Null(old.Counts);
            Assert.Equal("2 edited", old.Summary);

            // The journal gained the count columns, so a save made now keeps its counts beside the old row.
            await store.RecordAsync(Record(), Token);
            var entries = await store.ListAsync(Connection, cancellationToken: Token);
            Assert.Equal(["1 modifiée", "2 edited"], entries.Select(e => e.Summary));
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }
}
