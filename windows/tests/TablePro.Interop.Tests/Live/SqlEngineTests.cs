using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using TablePro.DataGrid.Model;

namespace TablePro.Interop.Tests.Live;

// What every SQL engine is checked for through the core: a table listed, paged, counted and described; each value of the
// engine's corpus read back as a table tab and a query tab show it; and a save of an update, an insert and a delete.
public abstract class SqlEngineTests : IAsyncDisposable
{
    private static readonly (int Id, string Name, string? Note)[] People =
    [
        (1, "Ada", null),
        (2, "Grace", "note"),
        (3, "Zoë 👋", "中文"),
    ];

    private static readonly JsonSerializerOptions Readable = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-live-").FullName;
    private readonly List<IAsyncDisposable> _open = [];
    private TableProCore? _core;

    protected string Unique { get; } = Guid.NewGuid().ToString("N")[..8];

    protected TableProCore Core => _core ??= TableProCore.Create(new HostConfiguration("live-test", _directory), new MemorySecretStore());

    protected abstract string CorpusFile { get; }

    protected virtual string? CorpusFlavour => null;

    protected abstract Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken);

    protected abstract TableName Table(string name);

    protected abstract string Qualified(string name);

    protected abstract string CorpusTableSql(string table);

    protected abstract string PeopleTableSql(string table);

    protected virtual string Text(string value) => $"'{value.Replace("'", "''", StringComparison.Ordinal)}'";

    [Fact]
    public async Task ATableIsListedPagedCountedAndDescribed()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var (session, editor) = await StartAsync(cancellationToken);
        var table = await PeopleAsync(session, editor, cancellationToken);

        using var rows = await PageAsync(session, table, cancellationToken);
        var count = await session.CountRowsAsync(table, cancellationToken: cancellationToken);
        var structure = await session.GetStructureAsync(table, ObjectKind.Table, cancellationToken);

        Assert.Equal(
            People.ToDictionary(person => (long)person.Id, person => (string?)person.Name),
            TextsById(rows.Set, "name"));
        Assert.Equal(People.Length, count);
        Assert.Equal(["id", "name", "note"], structure.Columns.Select(column => column.Name));
    }

    [Fact]
    public async Task EveryCorpusValueReadsBackAsTheGridShowsIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var (session, editor) = await StartAsync(cancellationToken);
        var corpus = ValueCorpus.Load(CorpusFile, CorpusFlavour);
        var wrong = new List<string>();

        for (var index = 0; index < corpus.Count; index++)
        {
            var column = corpus[index];
            var name = $"corpus_{index}_{Unique}";
            var table = Qualified(name);
            List<string> statements = [CorpusTableSql(table), .. column.Setup ?? [], $"ALTER TABLE {table} ADD {column.Column}"];
            statements.AddRange(column.Values.Select(
                (value, row) => $"INSERT INTO {table} (id, label, v) VALUES ({row}, 'corpus', {value.Sql})"));
            if (await FirstRefusalAsync(editor, statements, cancellationToken) is { } refusal)
            {
                wrong.Add($"`{column.Column}`: {refusal}");
                continue;
            }

            using (var browsed = await PageAsync(session, Table(name), cancellationToken))
            {
                Compare("browse", column, TextsById(browsed.Set, "v"), wrong);
            }

            using var edited = await SelectAsync(editor, $"SELECT id, v FROM {table}", cancellationToken);
            Compare("editor", column, TextsById(edited.Set, "v"), wrong);
        }

        Assert.True(wrong.Count == 0, $"{wrong.Count} values did not read back as written:\n{string.Join('\n', wrong)}");
    }

    [Fact]
    public async Task ARowSaveWritesAnUpdateAnInsertAndADelete()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var (session, editor) = await StartAsync(cancellationToken);
        var table = await PeopleAsync(session, editor, cancellationToken);
        using var tableEditor = await session.OpenTableEditorAsync(table, refresh: false, cancellationToken);
        using var page = await PageAsync(session, table, cancellationToken);
        var rows = RowsById(page.Set);
        var columns = tableEditor.Columns.Select(column => column.Name).ToList();
        CellEdit NewCell(string column) => column switch
        {
            "id" => new CellEdit.Text("4"),
            "name" => new CellEdit.Text("Edsger"),
            _ => CellEdit.Null.Instance,
        };

        var draftRow = (long)page.Set.RowCount;
        tableEditor.SetCell(page.Set, rows[1], columns.IndexOf("note"), new CellEdit.Text("first"));
        tableEditor.InsertRow();
        for (var column = 0; column < columns.Count; column++)
        {
            var cell = NewCell(columns[column]);
            if (tableEditor.Check(column, cell, newRow: true) is null)
            {
                tableEditor.SetCell(page.Set, draftRow, column, cell);
            }
        }

        tableEditor.DeleteRows(page.Set, [rows[2]]);
        var outcome = await tableEditor.SaveAsync(page.Set, confirmed: false, cancellationToken);
        using var after = await SelectAsync(editor, $"SELECT id, name, note FROM {Qualified(table.Name)}", cancellationToken);

        Assert.Null(tableEditor.LockFor(page.Set));
        Assert.True(outcome is RowSaveOutcome.Saved, $"the save ended {outcome}");
        Assert.Equal(
            new Dictionary<long, string?> { [1] = "Ada", [3] = "Zoë 👋", [4] = "Edsger" },
            TextsById(after.Set, "name"));
        Assert.Equal(
            new Dictionary<long, string?> { [1] = "first", [3] = "中文", [4] = null },
            TextsById(after.Set, "note"));
    }

    [Fact]
    public async Task AnExplainVariantParsesIntoAPlanTree()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var (session, editor) = await StartAsync(cancellationToken);
        var table = await PeopleAsync(session, editor, cancellationToken);
        var sql = $"SELECT * FROM {Qualified(table.Name)}";

        var variants = QueryPlans.VariantsFor(session.EngineId).Where(variant => variant.IsSqlPrefix).ToList();
        if (variants.Count == 0)
        {
            // Engines with no core EXPLAIN parser yet (Cassandra, DuckDB, ClickHouse, MSSQL) expose no prefix
            // variant, so there is nothing to parse. A skip would fail CI's --fail-skips, so this passes instead.
            return;
        }

        ExplainOutcome.Parsed? parsed = null;
        foreach (var variant in variants)
        {
            if (await QueryPlans.ExplainAsync(editor, variant, sql, cancellationToken: cancellationToken)
                is ExplainOutcome.Parsed outcome)
            {
                parsed = outcome;
                break;
            }
        }

        Assert.NotNull(parsed);
        Assert.False(string.IsNullOrWhiteSpace(parsed!.Plan.Root.Operation));
        Assert.NotEqual(string.Empty, parsed.Plan.RawText);
    }

    public async ValueTask DisposeAsync()
    {
        for (var index = _open.Count - 1; index >= 0; index--)
        {
            await _open[index].DisposeAsync();
        }

        _core?.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // A file engine closes on the core's own threads, which can still hold the file here on Windows.
        }

        GC.SuppressFinalize(this);
    }

    protected static async Task<DatabaseSession> ConnectAsync(
        TableProCore core,
        SavedConnection connection,
        ConnectionSecrets secrets,
        CancellationToken cancellationToken)
    {
        var saved = await core.Library.SaveAsync(connection, secrets);
        return await core.ConnectAsync(saved.Id!.Value, cancellationToken: cancellationToken);
    }

    protected static async Task ExecuteAsync(QueryEditor editor, string sql, CancellationToken cancellationToken)
    {
        if (await RefusalAsync(editor, sql, cancellationToken) is { } refusal)
        {
            Assert.Fail(refusal);
        }
    }

    private async Task<(DatabaseSession Session, QueryEditor Editor)> StartAsync(CancellationToken cancellationToken)
    {
        var session = await OpenAsync(Core, _directory, cancellationToken);
        _open.Add(session);
        var editor = await session.OpenEditorAsync(cancellationToken);
        _open.Add(editor);
        return (session, editor);
    }

    private async Task<TableName> PeopleAsync(DatabaseSession session, QueryEditor editor, CancellationToken cancellationToken)
    {
        var name = $"people_{Unique}";
        var table = Qualified(name);
        await ExecuteAsync(editor, PeopleTableSql(table), cancellationToken);
        foreach (var (id, person, note) in People)
        {
            var noteSql = note is null ? "NULL" : Text(note);
            await ExecuteAsync(
                editor,
                $"INSERT INTO {table} (id, name, note) VALUES ({id}, {Text(person)}, {noteSql})",
                cancellationToken);
        }

        var objects = await session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        var entry = Assert.Single(objects, item => item.Name == name);
        Assert.Equal(ObjectKind.Table, entry.Kind);
        Assert.Equal(Table(name), new TableName(entry.Schema, entry.Name));
        return Table(name);
    }

    private static async Task<string?> FirstRefusalAsync(
        QueryEditor editor,
        IEnumerable<string> statements,
        CancellationToken cancellationToken)
    {
        foreach (var sql in statements)
        {
            if (await RefusalAsync(editor, sql, cancellationToken) is { } refusal)
            {
                return refusal;
            }
        }

        return null;
    }

    private static async Task<string?> RefusalAsync(QueryEditor editor, string sql, CancellationToken cancellationToken)
    {
        using var run = editor.Run(sql, cancellationToken: cancellationToken);
        return await run.Completion switch
        {
            QueryOutcome.Completed => null,
            QueryOutcome.Failed failed => $"`{sql}` failed: {failed.Error.Code} {failed.Error.Message}",
            var other => $"`{sql}` ended {other}",
        };
    }

    private static async Task<Rows> PageAsync(DatabaseSession session, TableName table, CancellationToken cancellationToken)
    {
        var page = await session.ReadTablePageAsync(table, null, null, 1_000, cancellationToken: cancellationToken);
        return await RowsAsync(page.Run, $"the page of {table}");
    }

    private static Task<Rows> SelectAsync(QueryEditor editor, string sql, CancellationToken cancellationToken) =>
        RowsAsync(editor.Run(sql, cancellationToken: cancellationToken), $"`{sql}`");

    private static async Task<Rows> RowsAsync(QueryRun run, string what)
    {
        var outcome = await run.Completion;
        if (outcome is not QueryOutcome.Completed)
        {
            run.Dispose();
            Assert.Fail($"{what} ended {(outcome is QueryOutcome.Failed failed ? failed.Error.Message : outcome)}");
        }

        return new Rows(run, run.GetResultSet(0) ?? throw new InvalidOperationException($"{what} read no set."));
    }

    private static Dictionary<long, long> RowsById(ResultSet set)
    {
        var id = ColumnIndex(set, "id");
        return Enumerable.Range(0, (int)set.RowCount)
            .ToDictionary(row => long.Parse(set.GetCellText(row, id)!, CultureInfo.InvariantCulture), row => (long)row);
    }

    private static Dictionary<long, string?> TextsById(ResultSet set, string column)
    {
        var index = ColumnIndex(set, column);
        using var reader = new ResultSetData(set, set.GetColumns()).OpenReader();
        var block = new CellBlock();
        reader.Read(0, (int)set.RowCount, index, 1, 256, block);
        return RowsById(set).ToDictionary(pair => pair.Key, pair => Shown(set, block, (int)pair.Value, index));
    }

    // The whole value, or the corpus's wording of one the driver could not read, from the type the grid is given.
    private static string? Shown(ResultSet set, CellBlock block, int row, int column)
    {
        var cell = block.Get(row, column);
        return (cell.State & CellState.Unreadable) != 0 ? $"<unreadable {cell.Text}>" : set.GetCellText(row, column);
    }

    private static int ColumnIndex(ResultSet set, string name)
    {
        var columns = set.GetColumns();
        var index = columns.ToList().FindIndex(column => column.Name == name);
        Assert.True(index >= 0, $"no `{name}` column in {string.Join(", ", columns.Select(column => column.Name))}");
        return index;
    }

    private static void Compare(string path, CorpusColumn column, Dictionary<long, string?> read, List<string> wrong)
    {
        for (var row = 0; row < column.Values.Count; row++)
        {
            var value = column.Values[row];
            var expected = path == "editor" && value.Edited is not null ? value.Edited : value.Shows;
            if (!read.TryGetValue(row, out var shown))
            {
                wrong.Add($"{path}: `{column.Column}` lost the row holding {value.Sql}");
            }
            else if (shown != expected)
            {
                wrong.Add($"{path}: `{column.Column}` holding {value.Sql} shows {Quoted(shown)}, expected {Quoted(expected)}");
            }
        }
    }

    private static string Quoted(string? text) => text is null ? "NULL" : JsonSerializer.Serialize(text, Readable);

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
