namespace TablePro.Interop.Tests;

// A real SQLite file in a directory of its own, made and filled through the core.
internal sealed class SqliteDatabase : IAsyncDisposable
{
    public const int PeopleRows = 3;

    private readonly string _directory;

    private SqliteDatabase(string directory, TableProCore core, DatabaseSession session, QueryEditor editor)
    {
        _directory = directory;
        Core = core;
        Session = session;
        Editor = editor;
    }

    public TableProCore Core { get; }

    public DatabaseSession Session { get; }

    public QueryEditor Editor { get; }

    public string Path => System.IO.Path.Combine(_directory, "app.sqlite");

    public static async Task<SqliteDatabase> CreateAsync()
    {
        var directory = Directory.CreateTempSubdirectory("tablepro-interop-").FullName;
        var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());
        var session = await core.OpenFileAsync(
            new FileOpenOptions(System.IO.Path.Combine(directory, "app.sqlite"), Create: true));
        var editor = await session.OpenEditorAsync();
        var database = new SqliteDatabase(directory, core, session, editor);
        await database.ExecuteAsync("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT)");
        await database.ExecuteAsync(
            "INSERT INTO people (name, note) VALUES ('Ada', NULL), ('Grace', 'line one\nline two'), ('Zoë 👋', '中文')");
        return database;
    }

    public async Task ExecuteAsync(string sql)
    {
        using var run = Editor.Run(sql);
        var outcome = await run.Completion;
        Assert.IsType<QueryOutcome.Completed>(outcome);
    }

    public async ValueTask DisposeAsync()
    {
        await Editor.DisposeAsync();
        await Session.DisposeAsync();
        Core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }
}

internal sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<(Guid, SecretKind), string> _secrets = [];
    private readonly Dictionary<SecretItem, string> _items = [];
    private readonly Lock _lock = new();

    public string? Load(Guid connectionId, SecretKind kind)
    {
        lock (_lock)
        {
            return _secrets.GetValueOrDefault((connectionId, kind));
        }
    }

    public void Store(Guid connectionId, SecretKind kind, string secret, string label)
    {
        lock (_lock)
        {
            _secrets[(connectionId, kind)] = secret;
        }
    }

    public void Relabel(Guid connectionId, SecretKind kind, string label)
    {
    }

    public void Delete(Guid connectionId, SecretKind kind)
    {
        lock (_lock)
        {
            _secrets.Remove((connectionId, kind));
        }
    }

    public void DeleteConnection(Guid connectionId)
    {
        lock (_lock)
        {
            foreach (var key in _secrets.Keys.Where(key => key.Item1 == connectionId).ToList())
            {
                _secrets.Remove(key);
            }
        }
    }

    public string? LoadItem(SecretItem item)
    {
        lock (_lock)
        {
            return _items.GetValueOrDefault(item);
        }
    }

    public void StoreItem(SecretItem item, string secret)
    {
        lock (_lock)
        {
            _items[item] = secret;
        }
    }

    public void DeleteItem(SecretItem item)
    {
        lock (_lock)
        {
            _items.Remove(item);
        }
    }
}
