using Microsoft.Data.Sqlite;
using TablePro.Storage.Mcp;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Tests;

public sealed class McpClientStoreTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly InMemorySecretStore _vault = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    [Fact]
    public async Task AClientReadsBackWithItsHashFromTheVault()
    {
        var store = new McpClientStore(_temp.Paths, _vault);
        var client = Client("Claude Code") with { ConnectionIds = [Guid.NewGuid()], ExpiresAt = DateTimeOffset.Now.AddDays(90) };

        await store.SaveAsync(client, Token);
        var loaded = Assert.Single(await new McpClientStore(_temp.Paths, _vault).LoadAsync(Token));

        Assert.Equal(client.Id, loaded.Id);
        Assert.Equal(client.TokenHash, loaded.TokenHash);
        Assert.Equal(client.ConnectionIds, loaded.ConnectionIds);
        Assert.Equal(client.ExpiresAt, loaded.ExpiresAt);
        Assert.Equal(client.TokenHash, _vault.Get(McpClientStore.SecretKey(client.Id)));
    }

    [Fact]
    public async Task TheFileNeverHoldsTheHash()
    {
        var store = new McpClientStore(_temp.Paths, _vault);
        var client = Client("Cursor");

        await store.SaveAsync(client, Token);
        var text = await File.ReadAllTextAsync(store.FilePath, Token);

        Assert.Contains("Cursor", text, StringComparison.Ordinal);
        Assert.DoesNotContain(client.TokenHash!, text, StringComparison.Ordinal);
        Assert.StartsWith(SecretKeys.Prefix, McpClientStore.SecretKey(client.Id), StringComparison.Ordinal);
    }

    [Fact]
    public async Task SavingReplacesTheClientWithTheSameId()
    {
        var store = new McpClientStore(_temp.Paths, _vault);
        var client = Client("Zed");
        await store.SaveAsync(client, Token);

        await store.SaveAsync(client with { RevokedAt = DateTimeOffset.Now, TokenHash = null }, Token);
        var loaded = Assert.Single(await store.LoadAsync(Token));

        Assert.NotNull(loaded.RevokedAt);

        // A save without a hash keeps the one in the vault.
        Assert.Equal(client.TokenHash, loaded.TokenHash);
    }

    [Fact]
    public async Task DeletingRemovesTheRowAndTheVaultEntry()
    {
        var store = new McpClientStore(_temp.Paths, _vault);
        var keep = Client("Keep");
        var drop = Client("Drop");
        await store.SaveAsync(keep, Token);
        await store.SaveAsync(drop, Token);

        Assert.True(await store.DeleteAsync(drop.Id, Token));
        Assert.False(await store.DeleteAsync(drop.Id, Token));

        Assert.Equal([keep.Id], (await store.LoadAsync(Token)).Select(c => c.Id));
        Assert.Null(_vault.Get(McpClientStore.SecretKey(drop.Id)));
        Assert.NotNull(_vault.Get(McpClientStore.SecretKey(keep.Id)));
    }

    [Fact]
    public async Task AHashTheVaultLostReadsAsNull()
    {
        var store = new McpClientStore(_temp.Paths, _vault);
        var client = Client("Orphan");
        await store.SaveAsync(client, Token);

        _vault.Delete(McpClientStore.SecretKey(client.Id));

        Assert.Null(Assert.Single(await store.LoadAsync(Token)).TokenHash);
    }

    [Fact]
    public async Task TwoStoresOnOneFileDoNotLoseEachOthersWrites()
    {
        var first = new McpClientStore(_temp.Paths, _vault);
        var second = new McpClientStore(_temp.Paths, _vault);

        await Task.WhenAll(Enumerable.Range(0, 20).Select(i => (i % 2 == 0 ? first : second).SaveAsync(Client("c" + i), Token)));

        Assert.Equal(20, (await first.LoadAsync(Token)).Count);
    }

    [Fact]
    public async Task NoFileMeansNoClients() =>
        Assert.Empty(await new McpClientStore(_temp.Paths, _vault).LoadAsync(Token));

    private static StoredMcpClient Client(string name) => new()
    {
        Id = Guid.NewGuid(),
        Name = name,
        TokenHash = Convert.ToHexStringLower(Guid.NewGuid().ToByteArray()) + Convert.ToHexStringLower(Guid.NewGuid().ToByteArray()),
        TokenPrefix = "tp_1234567",
        Permission = "ReadWrite",
        CreatedAt = DateTimeOffset.Now,
    };
}

public sealed class McpAuditStoreTests : IDisposable
{
    private static readonly DateTimeOffset Start = new(2026, 10, 1, 9, 0, 0, TimeSpan.Zero);
    private readonly TempDirectory _temp = new();
    private readonly Clock _clock = new(Start);
    private readonly McpAuditStore _store;

    public McpAuditStoreTests()
    {
        _store = new McpAuditStore(_temp.File("mcp-audit.db"), McpAuditStore.DefaultRetention, _clock);
    }

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        _store.Dispose();
        SqliteConnection.ClearAllPools();
        _temp.Dispose();
    }

    [Fact]
    public async Task AnAppendedRowReadsBackWithEveryField()
    {
        var row = Row("execute_query", Start) with
        {
            ClientId = Guid.NewGuid(),
            ClientName = "Claude Code",
            ConnectionId = Guid.NewGuid(),
            ConnectionName = "Shop",
            ErrorCode = "denied",
            Message = "read only",
            SqlDigest = new string('a', 64),
            ElapsedMs = 12.5,
        };

        Assert.True(await _store.AppendAsync(row, Token));
        var read = Assert.Single(await _store.QueryAsync(new McpAuditQuery(), Token));

        Assert.Equal(row, read);
    }

    [Fact]
    public void TheDefaultFileAndRetentionMatchTheMacApp()
    {
        using var store = new McpAuditStore(_temp.Paths);

        Assert.Equal(Path.Combine(_temp.Path, "mcp-audit.db"), store.DatabasePath);
        Assert.Equal(TimeSpan.FromDays(90), McpAuditStore.DefaultRetention);
    }

    [Fact]
    public async Task RowsComeBackNewestFirstFilteredAndLimited()
    {
        var client = Guid.NewGuid();
        await _store.AppendAsync(Row("list_tables", Start) with { ClientId = client }, Token);
        await _store.AppendAsync(Row("pairing.approved", Start.AddMinutes(1), "auth") with { ClientId = client }, Token);
        await _store.AppendAsync(Row("describe_table", Start.AddMinutes(2)), Token);
        await _store.AppendAsync(Row("count_rows", Start.AddMinutes(3)) with { ClientId = client }, Token);

        var all = await _store.QueryAsync(new McpAuditQuery(), Token);
        var byClient = await _store.QueryAsync(new McpAuditQuery(ClientId: client), Token);
        var auth = await _store.QueryAsync(new McpAuditQuery(Category: "auth"), Token);
        var recent = await _store.QueryAsync(new McpAuditQuery(Since: Start.AddMinutes(2)), Token);
        var limited = await _store.QueryAsync(new McpAuditQuery(Limit: 2), Token);

        Assert.Equal(["count_rows", "describe_table", "pairing.approved", "list_tables"], all.Select(r => r.Action));
        Assert.Equal(["count_rows", "pairing.approved", "list_tables"], byClient.Select(r => r.Action));
        Assert.Equal(["pairing.approved"], auth.Select(r => r.Action));
        Assert.Equal(["count_rows", "describe_table"], recent.Select(r => r.Action));
        Assert.Equal(["count_rows", "describe_table"], limited.Select(r => r.Action));
    }

    [Fact]
    public async Task ARowWhoseIdIsAlreadyInTheLogIsRefused()
    {
        var row = Row("list_tables", Start);
        Assert.True(await _store.AppendAsync(row, Token));

        Assert.False(await _store.AppendAsync(row with { Action = "rewritten" }, Token));
        Assert.Equal("list_tables", Assert.Single(await _store.QueryAsync(new McpAuditQuery(), Token)).Action);
    }

    [Fact]
    public async Task PruningDropsRowsPastTheWindowAndKeepsTheChainVerifiable()
    {
        await _store.AppendAsync(Row("old", Start.AddDays(-91)), Token);
        await _store.AppendAsync(Row("older", Start.AddDays(-100)), Token);
        await _store.AppendAsync(Row("recent", Start.AddDays(-89)), Token);
        await _store.AppendAsync(Row("now", Start), Token);

        var removed = await _store.PruneAsync(McpAuditStore.DefaultRetention, Token);

        Assert.Equal(2, removed);
        Assert.Equal(["now", "recent"], (await _store.QueryAsync(new McpAuditQuery(), Token)).Select(r => r.Action));
        var verification = await _store.VerifyAsync(Token);
        Assert.True(verification.IsIntact);
        Assert.Equal(2, verification.Count);
    }

    [Fact]
    public async Task OpeningAStoreAppliesRetention()
    {
        await _store.AppendAsync(Row("ancient", Start.AddDays(-120)), Token);
        await _store.AppendAsync(Row("fresh", Start), Token);

        using var reopened = new McpAuditStore(_temp.File("mcp-audit.db"), McpAuditStore.DefaultRetention, _clock);

        Assert.Equal(1, await reopened.CountAsync(Token));
    }

    [Fact]
    public async Task ConcurrentAppendsFromTwoStoresAllLandOnOneChain()
    {
        using var other = new McpAuditStore(_temp.File("mcp-audit.db"), McpAuditStore.DefaultRetention, _clock);

        await Task.WhenAll(Enumerable.Range(0, 40).Select(i => (i % 2 == 0 ? _store : other).AppendAsync(Row("t" + i, Start), Token)));

        Assert.Equal(40, await _store.CountAsync(Token));
        var verification = await other.VerifyAsync(Token);
        Assert.True(verification.IsIntact, $"broken at {verification.BrokenAt}");
    }

    [Fact]
    public async Task AnEditedRowBreaksTheChainAtThatRow()
    {
        for (var i = 0; i < 5; i++)
        {
            await _store.AppendAsync(Row("t" + i, Start.AddSeconds(i)), Token);
        }

        await using (var connection = new SqliteConnection($"Data Source={_store.DatabasePath}"))
        {
            await connection.OpenAsync(Token);
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE audit_entries SET outcome = 'denied' WHERE action = 't2';";
            await command.ExecuteNonQueryAsync(Token);
        }

        var verification = await _store.VerifyAsync(Token);

        Assert.False(verification.IsIntact);
        Assert.Equal(2, verification.BrokenAt);
        Assert.Equal(2, verification.Count);
    }

    [Fact]
    public async Task ARowRemovedFromTheMiddleBreaksTheChain()
    {
        for (var i = 0; i < 4; i++)
        {
            await _store.AppendAsync(Row("t" + i, Start.AddSeconds(i)), Token);
        }

        await using (var connection = new SqliteConnection($"Data Source={_store.DatabasePath}"))
        {
            await connection.OpenAsync(Token);
            await using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM audit_entries WHERE action = 't1';";
            await command.ExecuteNonQueryAsync(Token);
        }

        Assert.Equal(2, (await _store.VerifyAsync(Token)).BrokenAt);
    }

    [Fact]
    public async Task ClearingStartsAFreshChain()
    {
        await _store.AppendAsync(Row("a", Start), Token);
        await _store.ClearAsync(Token);
        await _store.AppendAsync(Row("b", Start), Token);

        var verification = await _store.VerifyAsync(Token);

        Assert.True(verification.IsIntact);
        Assert.Equal(1, verification.Count);
    }

    [Fact]
    public async Task ALongMessageIsCut()
    {
        await _store.AppendAsync(Row("t", Start) with { Message = new string('m', 2_000) }, Token);

        var message = Assert.Single(await _store.QueryAsync(new McpAuditQuery(), Token)).Message!;

        Assert.Equal(McpAuditStore.MaxMessageChars + 3, message.Length);
        Assert.True((await _store.VerifyAsync(Token)).IsIntact);
    }

    [Fact]
    public void TheChainHashCoversEveryField()
    {
        var row = Row("t", Start) with { SqlDigest = "d", ClientName = "c", Message = "m" };
        var hash = McpAuditStore.ChainHash(row, 0, "prev");

        Assert.Equal(64, hash.Length);
        Assert.NotEqual(hash, McpAuditStore.ChainHash(row with { SqlDigest = "e" }, 0, "prev"));
        Assert.NotEqual(hash, McpAuditStore.ChainHash(row with { ClientName = "d" }, 0, "prev"));
        Assert.NotEqual(hash, McpAuditStore.ChainHash(row, 1, "prev"));
        Assert.NotEqual(hash, McpAuditStore.ChainHash(row, 0, "other"));
        Assert.NotEqual(hash, McpAuditStore.ChainHash(row with { Message = "m", ErrorCode = "x" }, 0, "prev"));
    }

    private static McpAuditRecord Row(string action, DateTimeOffset at, string category = "tool") =>
        new(Guid.NewGuid(), at, category, action, "succeeded");

    private sealed class Clock(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }
}
