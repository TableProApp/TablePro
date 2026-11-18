namespace TablePro.Interop.Tests.Live;

public sealed class MongoDbTests : IDisposable
{
    private const string Database = "tablepro";

    // The document of every BSON type the grid shows that core/crates/drivers/mongodb/tests/integration/statements.rs reads.
    private const string EveryType = "{_id: 1, oid: ObjectId('5f1d7a0c9b1e8b2a3c4d5e6f'), "
        + "at: ISODate('2024-05-06T07:08:09.010Z'), price: NumberDecimal('12.50'), big: NumberLong('9007199254740993'), "
        + "ratio: 0.5, flag: true, nothing: null, nested: {a: [1, 2]}, "
        + "uid: UUID('0e3f6f0e-8a3b-4b8e-9a7c-2f1d1b3c4d5e'), blob: BinData(0, 'AAEC'), "
        + "stamp: Timestamp({t: 1700000000, i: 3})}";

    private static readonly Dictionary<string, string?> EveryTypeShows = new()
    {
        ["_id"] = "1",
        ["oid"] = "5f1d7a0c9b1e8b2a3c4d5e6f",
        ["at"] = "2024-05-06 07:08:09.01+00:00",
        ["price"] = "12.50",
        ["big"] = "9007199254740993",
        ["ratio"] = "0.5",
        ["flag"] = "true",
        ["nothing"] = null,
        ["nested"] = """{"a": [1, 2]}""",
        ["uid"] = "0e3f6f0e-8a3b-4b8e-9a7c-2f1d1b3c4d5e",
        ["blob"] = "0x000102",
        ["stamp"] = """{"$timestamp": {"t": 1700000000, "i": 3}}""",
    };

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-live-").FullName;
    private readonly string _unique = Guid.NewGuid().ToString("N")[..8];
    private readonly TableProCore _core;

    public MongoDbTests()
    {
        _core = TableProCore.Create(new HostConfiguration("live-test", _directory), new MemorySecretStore());
    }

    [Fact]
    public async Task ACollectionIsListedPagedAndCounted()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(cancellationToken);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        var collection = await PeopleAsync(session, editor, cancellationToken);

        using var page = await PageAsync(session, collection, cancellationToken);
        var count = await session.CountRowsAsync(collection, cancellationToken: cancellationToken);

        Assert.Equal(
            new Dictionary<string, string?> { ["1"] = "Ada", ["2"] = "Grace", ["3"] = "Zoë 👋" },
            Texts(page.Set, "name"));
        Assert.Equal(3, count);
    }

    [Fact]
    public async Task EveryBsonTypeReadsBackAsTheGridShowsIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(cancellationToken);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        var name = $"types_{_unique}";
        await ExecuteAsync(editor, $"db.getCollection('{name}').insertOne({EveryType})", cancellationToken);
        var collection = await ListedAsync(session, name, cancellationToken);

        using var browsed = await PageAsync(session, collection, cancellationToken);
        using var found = await RowsAsync(editor.Run($"db.getCollection('{name}').find()", cancellationToken: cancellationToken));

        var wrong = Wrong("browse", browsed.Set).Concat(Wrong("editor", found.Set)).ToList();
        Assert.True(wrong.Count == 0, string.Join('\n', wrong));
    }

    [Fact]
    public async Task ADocumentSaveWritesAnUpdateAnInsertAndADelete()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(cancellationToken);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        var collection = await PeopleAsync(session, editor, cancellationToken);
        using var tableEditor = await session.OpenTableEditorAsync(collection, refresh: false, cancellationToken);
        using var page = await PageAsync(session, collection, cancellationToken);
        var rows = RowsById(page.Set);
        var columns = tableEditor.Columns.Select(column => column.Name).ToList();
        CellEdit NewCell(string column) => column switch
        {
            "_id" => new CellEdit.Text("4"),
            "name" => new CellEdit.Text("Edsger"),
            _ => CellEdit.Null.Instance,
        };

        using var save = tableEditor.Plan(page.Set,
        [
            new RowEdit.Update(rows["1"], [new CellChange(columns.IndexOf("note"), new CellEdit.Text("first"))]),
            new RowEdit.Insert([.. columns.Select(NewCell)]),
            new RowEdit.Delete(rows["2"]),
        ]);
        var outcome = await save.RunAsync(confirmed: false, cancellationToken);
        using var after = await RowsAsync(editor.Run($"db.getCollection('{collection.Name}').find()", cancellationToken: cancellationToken));

        Assert.True(outcome is RowSaveOutcome.Saved, $"the save ended {outcome}");
        Assert.Equal(
            new Dictionary<string, string?> { ["1"] = "Ada", ["3"] = "Zoë 👋", ["4"] = "Edsger" },
            Texts(after.Set, "name"));
        Assert.Equal(
            new Dictionary<string, string?> { ["1"] = "first", ["3"] = "中文", ["4"] = null },
            Texts(after.Set, "note"));
    }

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private async Task<DatabaseSession> ConnectAsync(CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("MONGODB");
        var saved = await _core.Library.SaveAsync(
            new SavedConnection(null, "MongoDB", "mongodb", LiveServer.Host, server.Port, Database, server.UserName, TlsSettings.Disabled),
            server.Secrets);
        return await _core.ConnectAsync(saved.Id!.Value, cancellationToken: cancellationToken);
    }

    private async Task<TableName> PeopleAsync(DatabaseSession session, QueryEditor editor, CancellationToken cancellationToken)
    {
        var name = $"people_{_unique}";
        await ExecuteAsync(
            editor,
            $"db.getCollection('{name}').insertMany([{{_id: 1, name: 'Ada', note: null}}, "
                + "{_id: 2, name: 'Grace', note: 'note'}, {_id: 3, name: 'Zoë 👋', note: '中文'}])",
            cancellationToken);
        return await ListedAsync(session, name, cancellationToken);
    }

    private static async Task<TableName> ListedAsync(DatabaseSession session, string name, CancellationToken cancellationToken)
    {
        var objects = await session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        var entry = Assert.Single(objects, item => item.Name == name);
        Assert.Equal(ObjectKind.Table, entry.Kind);
        return new TableName(entry.Schema, entry.Name);
    }

    private static async Task ExecuteAsync(QueryEditor editor, string statement, CancellationToken cancellationToken)
    {
        using var run = editor.Run(statement, cancellationToken: cancellationToken);
        var outcome = await run.Completion;
        Assert.True(outcome is QueryOutcome.Completed, $"`{statement}` ended {outcome}");
    }

    private static async Task<Rows> PageAsync(DatabaseSession session, TableName collection, CancellationToken cancellationToken)
    {
        var page = await session.ReadTablePageAsync(collection, null, null, 1_000, cancellationToken: cancellationToken);
        return await RowsAsync(page.Run);
    }

    private static async Task<Rows> RowsAsync(QueryRun run)
    {
        var outcome = await run.Completion;
        if (outcome is not QueryOutcome.Completed)
        {
            run.Dispose();
            Assert.Fail($"the read ended {outcome}");
        }

        return new Rows(run, run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set."));
    }

    private static IEnumerable<string> Wrong(string path, ResultSet set)
    {
        var columns = set.GetColumns().Select(column => column.Name).ToList();
        foreach (var (field, expected) in EveryTypeShows)
        {
            var index = columns.IndexOf(field);
            var shown = index < 0 ? "<no column>" : set.GetCellText(0, index);
            if (shown != expected)
            {
                yield return $"{path}: `{field}` shows {shown ?? "NULL"}, expected {expected ?? "NULL"}";
            }
        }
    }

    private static Dictionary<string, long> RowsById(ResultSet set)
    {
        var id = set.GetColumns().ToList().FindIndex(column => column.Name == "_id");
        return Enumerable.Range(0, (int)set.RowCount).ToDictionary(row => set.GetCellText(row, id)!, row => (long)row);
    }

    private static Dictionary<string, string?> Texts(ResultSet set, string column)
    {
        var index = set.GetColumns().ToList().FindIndex(item => item.Name == column);
        return RowsById(set).ToDictionary(pair => pair.Key, pair => set.GetCellText(pair.Value, index));
    }

    private sealed class Rows(QueryRun run, ResultSet set) : IDisposable
    {
        public ResultSet Set { get; } = set;

        public void Dispose()
        {
            Set.Dispose();
            run.Dispose();
        }
    }
}
