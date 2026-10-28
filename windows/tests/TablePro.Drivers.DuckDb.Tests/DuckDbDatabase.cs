using DuckDB.NET.Data;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.DuckDb.Tests;

/// <summary>A throwaway DuckDB file with a small library schema, opened through the driver.</summary>
internal sealed class DuckDbDatabase : IAsyncDisposable
{
    private const string Schema = """
        CREATE SEQUENCE authors_id_seq START 4;
        CREATE TABLE authors (
            id INTEGER PRIMARY KEY DEFAULT nextval('authors_id_seq'),
            name VARCHAR NOT NULL,
            email VARCHAR UNIQUE
        );
        CREATE TABLE books (
            id INTEGER PRIMARY KEY,
            author_id INTEGER NOT NULL REFERENCES authors (id),
            title VARCHAR NOT NULL,
            price DECIMAL(10,2) DEFAULT 0
        );
        CREATE INDEX ix_books_title ON books (title, price);
        CREATE TABLE notes (id INTEGER, body VARCHAR);
        CREATE VIEW cheap_books AS SELECT * FROM books WHERE price < 10;
        CREATE MACRO add_tax(p) AS p * 1.2;
        COMMENT ON COLUMN books.title IS 'Display title';
        INSERT INTO authors (id, name, email) VALUES (1, 'Ann', 'ann@example.com'), (2, 'Bob', 'bob@example.com'), (3, 'Cid', NULL);
        INSERT INTO books VALUES (1, 1, 'Alpha', 5), (2, 1, 'Beta', 12), (3, 2, 'Gamma', 20), (4, 2, 'Delta', 8), (5, 3, 'Epsilon', 30);
        INSERT INTO notes VALUES (1, 'one'), (2, 'two');
        """;

    private DuckDbDatabase(string path, IDatabaseSession session)
    {
        Path = path;
        Session = session;
    }

    public string Path { get; }

    public IDatabaseSession Session { get; }

    public static async Task<string> CreateFileAsync(CancellationToken cancellationToken)
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"tablepro-{Guid.NewGuid():N}.duckdb");
        await using var connection = new DuckDBConnection($"Data Source={path}");
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = Schema;
        await command.ExecuteNonQueryAsync(cancellationToken);
        return path;
    }

    public static void DeleteFile(string path)
    {
        foreach (var file in new[] { path, path + ".wal" })
        {
            try
            {
                File.Delete(file);
            }
            catch (IOException)
            {
                // A file still held by a closing handle is left to the temp folder's own cleanup.
            }
        }
    }

    public static async Task<DuckDbDatabase> CreateAsync(CancellationToken cancellationToken, string? startupCommands = null)
    {
        var path = await CreateFileAsync(cancellationToken);
        var profile = new ConnectionProfile { Name = "test", Engine = DatabaseEngine.DuckDb, FilePath = path, StartupCommands = startupCommands };
        var session = await new DuckDbDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), cancellationToken);
        return new DuckDbDatabase(path, session);
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
        DeleteFile(Path);
    }
}
