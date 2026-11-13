using TablePro.Interop;

namespace TablePro.DataGrid.Model.Tests;

// Against the real core and a real SQLite file, as the grid reads it.
[Trait("Needs", "Core")]
public sealed class CoreDataTests
{
    private const string Values =
        "SELECT 1 AS id, 'Ada' AS name, NULL AS note " +
        "UNION ALL SELECT 2, 'Grace', 'line one' || char(10) || 'line two' " +
        "UNION ALL SELECT 3, 'Zoë 👋', '中文' " +
        "UNION ALL SELECT 4, 'مرحبا بالعالم', printf('%.600c', 'x') " +
        "UNION ALL SELECT 5, 'tab' || char(9) || 'and \"quote\"', 'plain'";

    [Fact]
    public async Task CellsReadBackWithNullCutRightToLeftAndLossyMarks()
    {
        await using var database = await CoreDatabase.CreateAsync();
        using var data = await database.QueryAsync(Values);

        Assert.Equal(5, data.Data.RowCount);
        Assert.Equal(3, data.Data.ColumnCount);
        Assert.Equal("note", data.Data.GetColumnName(2));
        using var cache = new CellCache(data.Data.OpenReader());

        Assert.True(cache.Get(0, 2, 64).IsNull);
        Assert.Equal("Zoë 👋", cache.Get(2, 1, 64).Text.ToString());
        var shown = cache.Get(1, 2, 64);
        Assert.Equal("line one line two", shown.Text.ToString());
        Assert.Equal(CellState.Lossy, shown.State);
        var arabic = cache.Get(3, 1, 64);
        Assert.True(arabic.IsRightToLeft);
        var cut = cache.Get(3, 2, 64);
        Assert.True(cut.IsTruncated);
        Assert.Equal(65, cut.Text.Length);
        Assert.Equal(CellState.None, cache.Get(0, 0, 64).State);
    }

    [Fact]
    public async Task ACopyHasTheWholeValuesBack()
    {
        await using var database = await CoreDatabase.CreateAsync();
        using var data = await database.QueryAsync(Values);
        using var reader = data.Data.OpenReader();

        var tsv = GridCopy.Tsv(reader, new CellRange(0, 0, 4, 2), TestContext.Current.CancellationToken);

        var lines = tsv.Split("\r\n");
        Assert.Equal("1\tAda\t", lines[0]);
        Assert.Equal("2\tGrace\t\"line one\nline two\"", lines[1]);
        Assert.Equal("3\tZoë 👋\t中文", lines[2]);
        Assert.Equal($"4\tمرحبا بالعالم\t{new string('x', 600)}", lines[3]);
        Assert.Equal("5\t\"tab\tand \"\"quote\"\"\"\tplain", lines[4]);
        Assert.Equal("", lines[5]);
    }

    // The grid's fetch path over the real core allocates nothing once its blocks are loaded.
    [Fact]
    public async Task ScrollingAMillionRowsAllocatesNothingOnceTheCacheIsFull()
    {
        await using var database = await CoreDatabase.CreateAsync();
        using var data = await database.QueryAsync(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000) " +
            "SELECT x, 'row ' || x, x * 0.5, CASE WHEN x % 5 = 0 THEN NULL ELSE 'Nguyễn ' || x END FROM c",
            rowLimit: 1_000_000);
        Assert.Equal(1_000_000, data.Data.RowCount);
        using var cache = new CellCache(data.Data.OpenReader(), capacity: 64);
        var random = new Random(11);
        void Scroll(int steps)
        {
            for (var step = 0; step < steps; step++)
            {
                var top = random.Next(0, 999_970);
                for (var row = top; row < top + 26; row++)
                {
                    for (var column = 0; column < 4; column++)
                    {
                        _ = cache.Get(row, column, 256).Text.Length;
                    }
                }
            }
        }
        Scroll(200);
        Assert.Equal("row 500001", cache.Get(500_000, 1, 256).Text.ToString());
        var before = GC.GetAllocatedBytesForCurrentThread();
        Scroll(200);
        Assert.Equal(0, GC.GetAllocatedBytesForCurrentThread() - before);
    }
}

internal sealed class CoreDatabase : IAsyncDisposable
{
    private readonly string _directory;
    private readonly TableProCore _core;
    private readonly DatabaseSession _session;
    private readonly QueryEditor _editor;

    private CoreDatabase(string directory, TableProCore core, DatabaseSession session, QueryEditor editor)
    {
        _directory = directory;
        _core = core;
        _session = session;
        _editor = editor;
    }

    // With rules, the file is opened as a saved connection, since only a saved one has masking rules.
    public static async Task<CoreDatabase> CreateAsync(IReadOnlyList<MaskingRule>? rules = null)
    {
        var directory = Directory.CreateTempSubdirectory("tablepro-grid-").FullName;
        var core = TableProCore.Create(new HostConfiguration("test", directory), new NoSecrets());
        var path = Path.Combine(directory, "grid.sqlite");
        var session = await core.OpenFileAsync(new FileOpenOptions(path, Create: true));
        if (rules is not null)
        {
            await session.DisposeAsync();
            var saved = await core.Library.SaveAsync(
                new SavedConnection(null, "grid", "sqlite", string.Empty, 0, path, string.Empty, TlsSettings.Disabled)
                {
                    MaskingRules = rules,
                },
                ConnectionSecrets.None);
            session = await core.ConnectAsync(saved.Id!.Value);
        }

        var editor = await session.OpenEditorAsync();
        return new CoreDatabase(directory, core, session, editor);
    }

    public async Task<QueryResult> QueryAsync(string sql, long rowLimit = 10_000)
    {
        var run = _editor.Run(sql, new QueryOptions(RowLimit: rowLimit), TestContext.Current.CancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        var set = run.GetResultSet(0)!;
        return new QueryResult(run, set, new ResultSetData(set, set.GetColumns()));
    }

    public async ValueTask DisposeAsync()
    {
        await _editor.DisposeAsync();
        await _session.DisposeAsync();
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private sealed class NoSecrets : ISecretStore
    {
        public string? Load(Guid connectionId, SecretKind kind) => null;

        public void Store(Guid connectionId, SecretKind kind, string secret, string label)
        {
        }

        public void Relabel(Guid connectionId, SecretKind kind, string label)
        {
        }

        public void Delete(Guid connectionId, SecretKind kind)
        {
        }

        public void DeleteConnection(Guid connectionId)
        {
        }

        public string? LoadItem(SecretItem item) => null;

        public void StoreItem(SecretItem item, string secret)
        {
        }

        public void DeleteItem(SecretItem item)
        {
        }
    }
}

internal sealed class QueryResult(QueryRun run, ResultSet set, ResultSetData data) : IDisposable
{
    public ResultSetData Data { get; } = data;

    public void Dispose()
    {
        set.Dispose();
        run.Dispose();
    }
}
