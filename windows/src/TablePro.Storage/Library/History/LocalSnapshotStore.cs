using System.Globalization;
using Microsoft.Data.Sqlite;

namespace TablePro.Storage.Library.History;

/// <summary>A copy of a subject's text kept when it was saved.</summary>
public sealed record LocalSnapshot(long Id, string Subject, string Content, DateTimeOffset SavedAt);

/// <summary>
/// Keeps the last <see cref="RetainedCount"/> saved versions of each file in <c>file_versions.db</c>, as the macOS app
/// keeps the last 50 versions of each saved query. A subject is a key such as <see cref="FileSubject"/>, so saved
/// queries can share the store.
/// </summary>
public sealed class LocalSnapshotStore : IDisposable
{
    public const int RetainedCount = 50;

    // A generated dump saved fifty times would fill the disk; versions of something that large belong in Git.
    public const int MaxSnapshotChars = 4 * 1024 * 1024;

    private readonly string _connectionString;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private bool _initialized;

    public LocalSnapshotStore(AppPaths paths)
        : this(Path.Combine(paths.Root, "file_versions.db"))
    {
    }

    public LocalSnapshotStore(string databasePath)
    {
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = Path.GetFullPath(databasePath),
            Mode = SqliteOpenMode.ReadWriteCreate,

            // Snapshots are written once per save; pooling would only keep the file open after the app is done.
            Pooling = false,
            DefaultTimeout = 30,
        }.ToString();
    }

    /// <summary>Fires on a thread-pool thread after a subject's snapshots changed, with the subject.</summary>
    public event EventHandler<string>? Changed;

    /// <summary>The subject key of a file: its full path, in lower case because Windows paths ignore case.</summary>
    public static string FileSubject(string path) => "file:" + Path.GetFullPath(path).ToLowerInvariant();

    /// <summary>The subject key of a saved query.</summary>
    public static string FavoriteSubject(Guid favoriteId) => "favorite:" + favoriteId.ToString("D");

    /// <summary>
    /// Records <paramref name="content"/> as the newest version of <paramref name="subject"/>, unless it equals the
    /// newest one already kept or is too large. Returns whether a snapshot was added.
    /// </summary>
    public async Task<bool> RecordAsync(string subject, string content, DateTimeOffset? savedAt = null, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(subject);
        ArgumentNullException.ThrowIfNull(content);
        if (content.Length > MaxSnapshotChars)
        {
            return false;
        }

        var added = await RunAsync(connection =>
        {
            using var transaction = connection.BeginTransaction();
            using (var latest = connection.CreateCommand())
            {
                latest.Transaction = transaction;
                latest.CommandText = "SELECT content FROM snapshots WHERE subject = $subject ORDER BY id DESC LIMIT 1";
                latest.Parameters.AddWithValue("$subject", subject);
                if (latest.ExecuteScalar() is string newest && string.Equals(newest, content, StringComparison.Ordinal))
                {
                    return false;
                }
            }

            using (var insert = connection.CreateCommand())
            {
                insert.Transaction = transaction;
                insert.CommandText = "INSERT INTO snapshots (subject, content, saved_at) VALUES ($subject, $content, $savedAt)";
                insert.Parameters.AddWithValue("$subject", subject);
                insert.Parameters.AddWithValue("$content", content);
                insert.Parameters.AddWithValue("$savedAt", ToSeconds(savedAt ?? DateTimeOffset.UtcNow));
                insert.ExecuteNonQuery();
            }

            using (var prune = connection.CreateCommand())
            {
                prune.Transaction = transaction;
                prune.CommandText = string.Create(CultureInfo.InvariantCulture, $"""
                    DELETE FROM snapshots WHERE subject = $subject AND id NOT IN (
                        SELECT id FROM snapshots WHERE subject = $subject ORDER BY id DESC LIMIT {RetainedCount})
                    """);
                prune.Parameters.AddWithValue("$subject", subject);
                prune.ExecuteNonQuery();
            }

            transaction.Commit();
            return true;
        }, cancellationToken);

        if (added)
        {
            Changed?.Invoke(this, subject);
        }

        return added;
    }

    /// <summary>A subject's snapshots, newest first.</summary>
    public Task<IReadOnlyList<LocalSnapshot>> ListAsync(string subject, CancellationToken cancellationToken = default) =>
        RunAsync<IReadOnlyList<LocalSnapshot>>(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT id, subject, content, saved_at FROM snapshots WHERE subject = $subject ORDER BY id DESC";
            command.Parameters.AddWithValue("$subject", subject);
            using var reader = command.ExecuteReader();
            var snapshots = new List<LocalSnapshot>();
            while (reader.Read())
            {
                snapshots.Add(Read(reader));
            }

            return snapshots;
        }, cancellationToken);

    public Task<LocalSnapshot?> GetAsync(long id, CancellationToken cancellationToken = default) =>
        RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT id, subject, content, saved_at FROM snapshots WHERE id = $id";
            command.Parameters.AddWithValue("$id", id);
            using var reader = command.ExecuteReader();
            return reader.Read() ? Read(reader) : null;
        }, cancellationToken);

    /// <summary>Moves a subject's snapshots to a new key, so a renamed file keeps its history.</summary>
    public async Task MoveAsync(string fromSubject, string toSubject, CancellationToken cancellationToken = default)
    {
        if (string.Equals(fromSubject, toSubject, StringComparison.Ordinal))
        {
            return;
        }

        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "UPDATE snapshots SET subject = $to WHERE subject = $from";
            command.Parameters.AddWithValue("$from", fromSubject);
            command.Parameters.AddWithValue("$to", toSubject);
            return command.ExecuteNonQuery();
        }, cancellationToken);
        Changed?.Invoke(this, toSubject);
    }

    public async Task DeleteAsync(string subject, CancellationToken cancellationToken = default)
    {
        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM snapshots WHERE subject = $subject";
            command.Parameters.AddWithValue("$subject", subject);
            return command.ExecuteNonQuery();
        }, cancellationToken);
        Changed?.Invoke(this, subject);
    }

    public void Dispose() => _gate.Dispose();

    private static double ToSeconds(DateTimeOffset time) => time.ToUnixTimeMilliseconds() / 1000.0;

    private static LocalSnapshot Read(SqliteDataReader reader) => new(
        reader.GetInt64(0),
        reader.GetString(1),
        reader.GetString(2),
        DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(reader.GetDouble(3) * 1000)));

    private async Task<T> RunAsync<T>(Func<SqliteConnection, T> work, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            // Microsoft.Data.Sqlite's async calls complete synchronously, so the work goes to the thread pool.
            return await Task.Run(() =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(new SqliteConnectionStringBuilder(_connectionString).DataSource)!);
                using var connection = new SqliteConnection(_connectionString);
                connection.Open();
                if (!_initialized)
                {
                    using var schema = connection.CreateCommand();
                    schema.CommandText = """
                        PRAGMA journal_mode = WAL;
                        CREATE TABLE IF NOT EXISTS snapshots (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            subject TEXT NOT NULL,
                            content TEXT NOT NULL,
                            saved_at REAL NOT NULL
                        );
                        CREATE INDEX IF NOT EXISTS idx_snapshots_subject ON snapshots(subject, id);
                        """;
                    schema.ExecuteNonQuery();
                    _initialized = true;
                }

                return work(connection);
            }, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }
}
