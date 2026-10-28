using System.Security.Cryptography;
using Microsoft.Data.Sqlite;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Rewind;

/// <summary>How long and how much of the save journal is kept. A record is a convenience with a short life, never a backup.</summary>
/// <param name="MaxAge">Long enough to cover "I noticed the next morning", short enough that production rows do not sit on disk for a quarter.</param>
/// <param name="MaxPerTable">The newest saves kept for each table.</param>
/// <param name="MaxBytes">The total kept. The newest record always survives, however large.</param>
public sealed record RewindRetention(TimeSpan MaxAge, int MaxPerTable = 50, long MaxBytes = 32L * 1024 * 1024)
{
    public static readonly RewindRetention Default = new(TimeSpan.FromDays(7));
}

/// <summary>A saved change as the list shows it, read without decrypting its rows.</summary>
public sealed record RewindJournalEntry(
    Guid Id,
    Guid ConnectionId,
    string? Database,
    ObjectName Table,
    DateTimeOffset CapturedAt,
    int OperationCount,
    int ReversibleCount,
    string Summary,
    Guid? Restores,
    DateTimeOffset? RestoredAt);

/// <summary>
/// The Data Rewind journal: what each committed grid save looked like before it ran, in <c>rewind.db</c> under
/// <c>%LOCALAPPDATA%\TablePro</c>. It is real row data, unlike everything else the app stores, so every payload is
/// sealed with AES-GCM under a key kept in Windows Credential Manager, as macOS keeps its key in the keychain.
/// Losing the key loses the journal, which is the right trade for a short-lived convenience.
/// </summary>
public sealed class RewindJournalStore : IDisposable
{
    /// <summary>The Credential Manager entry holding the journal's key.</summary>
    public const string KeySecret = SecretKeys.Prefix + "rewind/key";

    private const int NonceSize = 12;
    private const int TagSize = 16;

    private readonly string _connectionString;
    private readonly ISecretStore _secrets;
    private readonly RewindRetention _retention;
    private readonly SemaphoreSlim _initGate = new(1, 1);
    private readonly Lock _keyGate = new();
    private volatile bool _initialized;

    public RewindJournalStore(AppPaths paths, ISecretStore secrets, RewindRetention? retention = null)
        : this(Path.Combine((paths ?? throw new ArgumentNullException(nameof(paths))).Root, "rewind.db"), secrets, retention)
    {
    }

    public RewindJournalStore(string databasePath, ISecretStore secrets, RewindRetention? retention = null)
    {
        ArgumentNullException.ThrowIfNull(secrets);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = Path.GetFullPath(databasePath),
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = true,
            DefaultTimeout = 30,
        }.ToString();
        _secrets = secrets;
        _retention = retention ?? RewindRetention.Default;
    }

    /// <summary>Fires on a thread-pool thread after records were added, restored or removed.</summary>
    public event EventHandler? Changed;

    /// <summary>Seals and stores a record, then prunes to the retention.</summary>
    public async Task RecordAsync(RewindRecord record, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(record);
        var payload = Seal(record);
        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = """
                INSERT INTO rewind (id, connection_id, database_name, schema_name, table_name, engine, captured_at,
                                    operation_count, reversible_count, summary, restores_id, byte_count, payload)
                VALUES ($id, $connection, $database, $schema, $table, $engine, $at, $ops, $reversible, $summary, $restores, $bytes, $payload);
                """;
            command.Parameters.AddWithValue("$id", Key(record.Id));
            command.Parameters.AddWithValue("$connection", Key(record.ConnectionId));
            command.Parameters.AddWithValue("$database", (object?)record.Database ?? DBNull.Value);
            command.Parameters.AddWithValue("$schema", (object?)record.Table.Schema ?? DBNull.Value);
            command.Parameters.AddWithValue("$table", record.Table.Name);
            command.Parameters.AddWithValue("$engine", record.Engine.ToString());
            command.Parameters.AddWithValue("$at", record.CapturedAt.ToUnixTimeMilliseconds());
            command.Parameters.AddWithValue("$ops", record.Operations.Count);
            command.Parameters.AddWithValue("$reversible", record.ReversibleCount);
            command.Parameters.AddWithValue("$summary", record.Summary);
            command.Parameters.AddWithValue("$restores", record.Restores is { } restores ? Key(restores) : DBNull.Value);
            command.Parameters.AddWithValue("$bytes", payload.Length);
            command.Parameters.AddWithValue("$payload", payload);
            return command.ExecuteNonQuery();
        }, cancellationToken);

        await PruneAsync(DateTimeOffset.UtcNow, cancellationToken);
        OnChanged();
    }

    public void Dispose() => _initGate.Dispose();

    /// <summary>The newest saves on one connection, optionally against one table.</summary>
    public Task<IReadOnlyList<RewindJournalEntry>> ListAsync(Guid connectionId, ObjectName? table = null, int limit = 50, CancellationToken cancellationToken = default)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        return RunAsync<IReadOnlyList<RewindJournalEntry>>(connection =>
        {
            using var command = connection.CreateCommand();
            var sql = """
                SELECT id, connection_id, database_name, schema_name, table_name, captured_at, operation_count,
                       reversible_count, summary, restores_id, restored_at
                  FROM rewind WHERE connection_id = $connection
                """;
            command.Parameters.AddWithValue("$connection", Key(connectionId));
            if (table is { } name)
            {
                sql += " AND table_name = $table AND " + (name.Schema is null ? "schema_name IS NULL" : "schema_name = $schema");
                command.Parameters.AddWithValue("$table", name.Name);
                if (name.Schema is not null)
                {
                    command.Parameters.AddWithValue("$schema", name.Schema);
                }
            }

            command.CommandText = sql + " ORDER BY captured_at DESC, id DESC LIMIT $limit;";
            command.Parameters.AddWithValue("$limit", limit);
            var entries = new List<RewindJournalEntry>();
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                entries.Add(new RewindJournalEntry(
                    Guid.Parse(reader.GetString(0)),
                    Guid.Parse(reader.GetString(1)),
                    reader.IsDBNull(2) ? null : reader.GetString(2),
                    new ObjectName(reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetString(4)),
                    DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(5)),
                    reader.GetInt32(6),
                    reader.GetInt32(7),
                    reader.GetString(8),
                    reader.IsDBNull(9) ? null : Guid.Parse(reader.GetString(9)),
                    reader.IsDBNull(10) ? null : DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(10))));
            }

            return entries;
        }, cancellationToken);
    }

    /// <summary>The full record, or null when it is gone or can no longer be opened (the key was cleared).</summary>
    public async Task<RewindRecord?> GetAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var payload = await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT payload FROM rewind WHERE id = $id;";
            command.Parameters.AddWithValue("$id", Key(id));
            return command.ExecuteScalar() as byte[];
        }, cancellationToken);

        return payload is null ? null : TryOpen(id, payload);
    }

    /// <summary>Marks a save as restored, so the list can say so and offer the restore's own record instead.</summary>
    public async Task MarkRestoredAsync(Guid id, DateTimeOffset when, CancellationToken cancellationToken = default)
    {
        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "UPDATE rewind SET restored_at = $at WHERE id = $id;";
            command.Parameters.AddWithValue("$at", when.ToUnixTimeMilliseconds());
            command.Parameters.AddWithValue("$id", Key(id));
            return command.ExecuteNonQuery();
        }, cancellationToken);
        OnChanged();
    }

    public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var removed = await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM rewind WHERE id = $id;";
            command.Parameters.AddWithValue("$id", Key(id));
            return command.ExecuteNonQuery();
        }, cancellationToken);
        if (removed > 0)
        {
            OnChanged();
        }

        return removed > 0;
    }

    /// <summary>Drops every record and the key that opens them, so nothing left on disk can be read.</summary>
    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM rewind; PRAGMA incremental_vacuum;";
            return command.ExecuteNonQuery();
        }, cancellationToken);
        lock (_keyGate)
        {
            _secrets.Delete(KeySecret);
        }

        OnChanged();
    }

    /// <summary>Age, then depth per table, then total bytes, as macOS prunes. Returns how many records went.</summary>
    public Task<int> PruneAsync(DateTimeOffset now, CancellationToken cancellationToken = default) =>
        RunAsync(connection =>
        {
            using var command = connection.CreateCommand();

            // The byte budget counts what newer records already hold, so a single save larger than the budget is the
            // one that survives rather than the one that deletes itself the moment it is written.
            command.CommandText = """
                DELETE FROM rewind WHERE captured_at < $cutoff;
                DELETE FROM rewind WHERE id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY connection_id, database_name, schema_name, table_name
                            ORDER BY captured_at DESC, id DESC) AS depth
                        FROM rewind)
                    WHERE depth > $depth);
                DELETE FROM rewind WHERE id IN (
                    SELECT id FROM (
                        SELECT id, COALESCE(SUM(byte_count) OVER (
                            ORDER BY captured_at DESC, id DESC
                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS retained
                        FROM rewind)
                    WHERE retained > $bytes);
                """;
            command.Parameters.AddWithValue("$cutoff", (now - _retention.MaxAge).ToUnixTimeMilliseconds());
            command.Parameters.AddWithValue("$depth", _retention.MaxPerTable);
            command.Parameters.AddWithValue("$bytes", _retention.MaxBytes);
            return command.ExecuteNonQuery();
        }, cancellationToken);

    private byte[] Seal(RewindRecord record)
    {
        var plaintext = RewindRecordCodec.Serialize(record);
        var sealedPayload = new byte[NonceSize + TagSize + plaintext.Length];
        var nonce = sealedPayload.AsSpan(0, NonceSize);
        RandomNumberGenerator.Fill(nonce);
        using var aes = new AesGcm(GetOrCreateKey(), TagSize);

        // The record's id is bound as associated data, so a payload copied onto another row will not open.
        aes.Encrypt(nonce, plaintext, sealedPayload.AsSpan(NonceSize + TagSize), sealedPayload.AsSpan(NonceSize, TagSize), record.Id.ToByteArray());
        CryptographicOperations.ZeroMemory(plaintext);
        return sealedPayload;
    }

    private RewindRecord? TryOpen(Guid id, byte[] payload)
    {
        if (payload.Length < NonceSize + TagSize || GetKey() is not { } key)
        {
            return null;
        }

        var plaintext = new byte[payload.Length - NonceSize - TagSize];
        try
        {
            using var aes = new AesGcm(key, TagSize);
            aes.Decrypt(payload.AsSpan(0, NonceSize), payload.AsSpan(NonceSize + TagSize), payload.AsSpan(NonceSize, TagSize), plaintext, id.ToByteArray());
            return RewindRecordCodec.Deserialize(plaintext);
        }
        catch (Exception ex) when (ex is CryptographicException or System.Text.Json.JsonException or FormatException)
        {
            return null;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private byte[]? GetKey()
    {
        lock (_keyGate)
        {
            return _secrets.Get(KeySecret) is { } encoded && TryDecodeKey(encoded, out var key) ? key : null;
        }
    }

    private byte[] GetOrCreateKey()
    {
        lock (_keyGate)
        {
            if (_secrets.Get(KeySecret) is { } encoded && TryDecodeKey(encoded, out var existing))
            {
                return existing;
            }

            var key = RandomNumberGenerator.GetBytes(32);
            _secrets.Set(KeySecret, Convert.ToBase64String(key));
            return key;
        }
    }

    private static bool TryDecodeKey(string encoded, out byte[] key)
    {
        key = new byte[32];
        return Convert.TryFromBase64String(encoded, key, out var written) && written == 32;
    }

    private static string Key(Guid id) => id.ToString("D");

    private async Task InitializeAsync(CancellationToken cancellationToken)
    {
        if (_initialized)
        {
            return;
        }

        await _initGate.WaitAsync(cancellationToken);
        try
        {
            if (_initialized)
            {
                return;
            }

            var directory = Path.GetDirectoryName(new SqliteConnectionStringBuilder(_connectionString).DataSource);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            await Task.Run(CreateSchema, cancellationToken);
            _initialized = true;
        }
        finally
        {
            _initGate.Release();
        }
    }

    private void CreateSchema()
    {
        using var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var command = connection.CreateCommand();

        // auto_vacuum must be set before the first table exists, so cleared records do not leave their bytes in free pages.
        command.CommandText = """
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS rewind (
                id TEXT PRIMARY KEY NOT NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT,
                schema_name TEXT,
                table_name TEXT NOT NULL,
                engine TEXT NOT NULL,
                captured_at INTEGER NOT NULL,
                operation_count INTEGER NOT NULL,
                reversible_count INTEGER NOT NULL,
                summary TEXT NOT NULL,
                restores_id TEXT,
                restored_at INTEGER,
                byte_count INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS rewind_target ON rewind (connection_id, table_name, captured_at DESC);
            CREATE INDEX IF NOT EXISTS rewind_age ON rewind (captured_at DESC);
            """;
        command.ExecuteNonQuery();
    }

    private async Task<T> RunAsync<T>(Func<SqliteConnection, T> work, CancellationToken cancellationToken)
    {
        await InitializeAsync(cancellationToken);
        return await Task.Run(() =>
        {
            using var connection = new SqliteConnection(_connectionString);
            connection.Open();
            return work(connection);
        }, cancellationToken);
    }

    private void OnChanged() => Changed?.Invoke(this, EventArgs.Empty);
}
