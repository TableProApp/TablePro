using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.Sqlite.Tests;

/// <summary>A throwaway database file with a small library schema, opened through the driver.</summary>
internal sealed class SqliteDatabase : IAsyncDisposable
{
    // The seed authors name their created time: two files made either side of a second boundary would otherwise differ
    // in every author, and the compare and sync tests would see changes nobody made.
    private const string Schema = """
        CREATE TABLE authors (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT UNIQUE,
            created TEXT DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE books (
            id INTEGER PRIMARY KEY,
            author_id INTEGER NOT NULL,
            title TEXT NOT NULL COLLATE NOCASE,
            price REAL DEFAULT 0 CHECK (price >= 0),
            CONSTRAINT fk_books_author FOREIGN KEY (author_id) REFERENCES authors (id) ON DELETE CASCADE
        );
        CREATE INDEX ix_books_title ON books (title, price);
        CREATE VIEW cheap_books AS SELECT * FROM books WHERE price < 10;
        CREATE TRIGGER trg_books_ai AFTER INSERT ON books BEGIN UPDATE books SET price = price WHERE id = NEW.id; END;
        INSERT INTO authors (name, email, created) VALUES
            ('Ann', 'ann@example.com', '2024-01-01 00:00:00'), ('Bob', 'bob@example.com', '2024-01-01 00:00:00'), ('Cid', NULL, '2024-01-01 00:00:00');
        INSERT INTO books (id, author_id, title, price) VALUES
            (1, 1, 'Alpha', 5), (2, 1, 'Beta', 12), (3, 2, 'Gamma', 20), (4, 2, 'Delta', 8), (5, 3, 'Epsilon', 30);
        """;

    private SqliteDatabase(string path, IDatabaseSession session)
    {
        Path = path;
        Session = session;
    }

    public string Path { get; }

    public IDatabaseSession Session { get; }

    public static async Task<SqliteDatabase> CreateAsync(CancellationToken cancellationToken, string? startupCommands = null)
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"tablepro-{Guid.NewGuid():N}.db");
        await using (var connection = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = Schema;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        var profile = new ConnectionProfile { Name = "test", Engine = DatabaseEngine.Sqlite, FilePath = path, StartupCommands = startupCommands };
        var session = await new SqliteDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), cancellationToken);
        return new SqliteDatabase(path, session);
    }

    public async Task<List<StatementResult>> RunAsync(IReadOnlyList<string> statements, CancellationToken cancellationToken)
    {
        await using var channel = await Session.OpenChannelAsync(cancellationToken);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), cancellationToken))
        {
            results.Add(result);
        }

        return results;
    }

    public async ValueTask DisposeAsync()
    {
        await Session.DisposeAsync();
        SqliteConnection.ClearAllPools();
        try
        {
            File.Delete(Path);
        }
        catch (IOException)
        {
            // A file still held by a finalizing handle is left to the temp folder's own cleanup.
        }
    }
}
