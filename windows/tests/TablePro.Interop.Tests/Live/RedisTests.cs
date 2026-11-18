namespace TablePro.Interop.Tests.Live;

public sealed class RedisTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-live-").FullName;
    private readonly string _prefix = $"tp:{Guid.NewGuid().ToString("N")[..8]}:";
    private readonly TableProCore _core;

    public RedisTests()
    {
        _core = TableProCore.Create(new HostConfiguration("live-test", _directory), new MemorySecretStore());
    }

    [Fact]
    public async Task EveryKeyTypeIsListedAndReadsBackAsTheGridShowsIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(cancellationToken);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        foreach (var command in new[]
        {
            $"SET {_prefix}text \"naïve café 🦀\"",
            $"SET {_prefix}bytes \"\\xff\\x00\\xfe\"",
            $"HSET {_prefix}hash f1 v1 f2 \"two words\"",
            $"RPUSH {_prefix}list a b c",
            $"SADD {_prefix}set x y",
            $"ZADD {_prefix}zset 1.5 m1 -0.25 m2",
            $"XADD {_prefix}stream 1-1 a 1 b 2",
        })
        {
            await ExecuteAsync(editor, command, cancellationToken);
        }

        // The core lists no keys through the FFI yet (the Linux sidebar's listing), so the editor lists them.
        using var listed = editor.Run($"KEYS {_prefix}*", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await listed.Completion);
        using var keys = listed.GetResultSet(0);
        Assert.NotNull(keys);
        var value = keys.GetColumns().ToList().FindIndex(column => column.Name == "value");

        Assert.Equal(
            ["bytes", "hash", "list", "set", "stream", "text", "zset"],
            Enumerable.Range(0, (int)keys.RowCount).Select(row => keys.GetCellText(row, value)![_prefix.Length..]).Order(StringComparer.Ordinal));
        Assert.Equal((KeyKind.Text, Rows(["naïve café 🦀"])), await ReadAsync(session, "text", cancellationToken));
        Assert.Equal((KeyKind.Text, Rows(["0xff00fe"])), await ReadAsync(session, "bytes", cancellationToken));
        Assert.Equal((KeyKind.Hash, Rows(["f1", "v1"], ["f2", "two words"])), await ReadAsync(session, "hash", cancellationToken, sorted: true));
        Assert.Equal((KeyKind.List, Rows(["0", "a"], ["1", "b"], ["2", "c"])), await ReadAsync(session, "list", cancellationToken));
        Assert.Equal((KeyKind.Set, Rows(["x"], ["y"])), await ReadAsync(session, "set", cancellationToken, sorted: true));
        Assert.Equal((KeyKind.SortedSet, Rows(["m2", "-0.25"], ["m1", "1.5"])), await ReadAsync(session, "zset", cancellationToken));
        Assert.Equal((KeyKind.Stream, Rows(["1-1", """{"a":"1","b":"2"}"""])), await ReadAsync(session, "stream", cancellationToken));
    }

    [Fact]
    public async Task AWriteFromTheEditorReadsBackAndADeletedKeyIsGone()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(cancellationToken);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        await ExecuteAsync(editor, $"HSET {_prefix}hash f1 v1", cancellationToken);
        await ExecuteAsync(editor, $"SET {_prefix}gone x EX 3600", cancellationToken);
        var before = await ReadWindowAsync(session, "gone", cancellationToken);

        await ExecuteAsync(editor, $"HSET {_prefix}hash f1 changed", cancellationToken);
        await ExecuteAsync(editor, $"DEL {_prefix}gone", cancellationToken);
        var hash = await ReadAsync(session, "hash", cancellationToken);
        var after = await ReadWindowAsync(session, "gone", cancellationToken);

        var ttl = Assert.IsType<KeyTtl.ExpiresIn>(before?.Ttl);
        Assert.InRange(ttl.Left, TimeSpan.FromMinutes(55), TimeSpan.FromHours(1));
        Assert.Equal((KeyKind.Hash, Rows(["f1", "changed"])), hash);
        Assert.Null(after);
    }

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private async Task<DatabaseSession> ConnectAsync(CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("REDIS");
        var saved = await _core.Library.SaveAsync(
            new SavedConnection(null, "Redis", "redis", LiveServer.Host, server.Port, "0", server.UserName, TlsSettings.Disabled),
            server.Secrets);
        return await _core.ConnectAsync(saved.Id!.Value, cancellationToken: cancellationToken);
    }

    private static async Task ExecuteAsync(QueryEditor editor, string command, CancellationToken cancellationToken)
    {
        using var run = editor.Run(command, cancellationToken: cancellationToken);
        var outcome = await run.Completion;
        Assert.True(outcome is QueryOutcome.Completed, $"`{command}` ended {outcome}");
    }

    private async Task<KeyWindow?> ReadWindowAsync(DatabaseSession session, string key, CancellationToken cancellationToken)
    {
        using var reader = session.OpenKey(_prefix + key);
        return await reader.ReadMoreAsync(cancellationToken);
    }

    private async Task<(KeyKind, string)> ReadAsync(
        DatabaseSession session,
        string key,
        CancellationToken cancellationToken,
        bool sorted = false)
    {
        using var reader = session.OpenKey(_prefix + key);
        var window = await reader.ReadMoreAsync(cancellationToken);
        Assert.NotNull(window);
        Assert.False(window.HasMore);
        using var set = reader.GetRows();
        Assert.NotNull(set);
        var columns = set.GetColumns().Count;
        var rows = Enumerable.Range(0, (int)set.RowCount)
            .Select(row => string.Join(" | ", Enumerable.Range(0, columns).Select(column => set.GetCellText(row, column) ?? "NULL")))
            .ToList();
        return (window.Kind, string.Join('\n', sorted ? [.. rows.Order(StringComparer.Ordinal)] : rows));
    }

    private static string Rows(params string[][] rows) => string.Join('\n', rows.Select(row => string.Join(" | ", row)));
}
