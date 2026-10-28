using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;

namespace TablePro.Storage.Mcp;

/// <summary>One persisted MCP audit row. Category and outcome are the MCP layer's names, kept as text.</summary>
/// <param name="Id">Unique per row; a second row with the same id is refused, never overwritten.</param>
/// <param name="Timestamp">When it happened. Kept to the millisecond.</param>
/// <param name="Category"><c>tool</c>, <c>auth</c> or <c>admin</c>.</param>
/// <param name="Action">The tool name, or the action such as <c>pairing.approved</c>.</param>
/// <param name="Outcome">How it ended, such as <c>succeeded</c> or <c>denied</c>.</param>
/// <param name="ClientId">The paired client it is about, if any.</param>
/// <param name="ClientName">That client's name at the time.</param>
/// <param name="ConnectionId">The connection a tool touched.</param>
/// <param name="ConnectionName">That connection's name at the time.</param>
/// <param name="ErrorCode">The failure's code.</param>
/// <param name="Message">A short note; longer text is cut to <see cref="McpAuditStore.MaxMessageChars"/>.</param>
/// <param name="SqlDigest">SHA-256 of the statement a tool ran. The statement itself is never stored.</param>
/// <param name="ElapsedMs">How long it took.</param>
public sealed record McpAuditRecord(
    Guid Id,
    DateTimeOffset Timestamp,
    string Category,
    string Action,
    string Outcome,
    Guid? ClientId = null,
    string? ClientName = null,
    Guid? ConnectionId = null,
    string? ConnectionName = null,
    string? ErrorCode = null,
    string? Message = null,
    string? SqlDigest = null,
    double ElapsedMs = 0);

/// <summary>Which rows to read. Every filter is optional; rows come back newest first.</summary>
public sealed record McpAuditQuery(Guid? ClientId = null, string? Category = null, DateTimeOffset? Since = null, int Limit = 500);

/// <summary>Whether the rows still chain: <see cref="BrokenAt"/> is the sequence of the first row that does not.</summary>
public sealed record McpAuditVerification(int Count, long? BrokenAt)
{
    public bool IsIntact => BrokenAt is null;
}

/// <summary>
/// The MCP audit log in <c>mcp-audit.db</c>, a SQLite database of its own beside the query history, kept for 90 days
/// as on macOS. Each row carries a sequence number and a SHA-256 over its fields and the previous row's hash, so a row
/// edited or removed from the middle shows up in <see cref="VerifyAsync"/>. Pruning removes from the old end, which
/// keeps the remaining chain verifiable.
/// </summary>
/// <remarks>
/// The store keeps no state between calls: each append reads the chain head inside its own write transaction, so the
/// server and the settings page can each open one without either getting a stale head. The file sits in the user's
/// <c>%LOCALAPPDATA%</c>, whose ACL already keeps other accounts out (macOS sets mode 0600 for the same end).
/// </remarks>
public sealed class McpAuditStore : IDisposable
{
    public static readonly TimeSpan DefaultRetention = TimeSpan.FromDays(90);

    public const int MaxMessageChars = 500;

    private const string GenesisHash = "0000000000000000000000000000000000000000000000000000000000000000";

    // Pruning on every append would make each one pay for a delete; every few hundred keeps the table near its window.
    private const int AppendsBetweenPrunes = 250;

    private const string Columns =
        "id, timestamp, category, action, outcome, client_id, client_name, connection_id, connection_name, error_code, message, sql_digest, elapsed_ms";

    private readonly string _connectionString;
    private readonly TimeSpan? _retention;
    private readonly TimeProvider _time;
    private readonly SemaphoreSlim _initGate = new(1, 1);
    private volatile bool _initialized;
    private int _appendsSincePrune;

    public McpAuditStore(AppPaths paths)
        : this(Path.Combine(paths.Root, "mcp-audit.db"), DefaultRetention)
    {
    }

    /// <param name="databasePath">The SQLite file, created on first use.</param>
    /// <param name="retention">How long rows are kept, applied on open and every few hundred appends. Null keeps them all.</param>
    /// <param name="time">The clock retention measures against, which tests replace.</param>
    public McpAuditStore(string databasePath, TimeSpan? retention, TimeProvider? time = null)
    {
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = Path.GetFullPath(databasePath),
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = true,
            DefaultTimeout = 30,
        }.ToString();
        _retention = retention;
        _time = time ?? TimeProvider.System;
    }

    /// <summary>Fires on a thread-pool thread after rows were added or removed.</summary>
    public event EventHandler? Changed;

    public string DatabasePath => new SqliteConnectionStringBuilder(_connectionString).DataSource;

    /// <summary>The digest a row's chain link covers, exposed so tests can forge and detect tampering.</summary>
    public static string ChainHash(McpAuditRecord record, long sequence, string previousHash)
    {
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(previousHash);
        string[] fields =
        [
            sequence.ToString(CultureInfo.InvariantCulture),
            Key(record.Id),
            record.Timestamp.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
            record.Category,
            record.Action,
            record.Outcome,
            record.ClientId is { } client ? Key(client) : string.Empty,
            record.ClientName ?? string.Empty,
            record.ConnectionId is { } connection ? Key(connection) : string.Empty,
            record.ConnectionName ?? string.Empty,
            record.ErrorCode ?? string.Empty,
            record.Message ?? string.Empty,
            record.SqlDigest ?? string.Empty,
            previousHash,
        ];

        // The unit separator cannot appear in any field the app writes, so no two field lists join to the same text.
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\u001F', fields))));
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
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

            var directory = Path.GetDirectoryName(DatabasePath);
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

        if (_retention is { } retention)
        {
            await PruneAsync(retention, cancellationToken);
        }
    }

    /// <returns>False when a row with the same id is already in the log.</returns>
    public async Task<bool> AppendAsync(McpAuditRecord record, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (record.Message is { Length: > MaxMessageChars } message)
        {
            record = record with { Message = string.Concat(message.AsSpan(0, MaxMessageChars), "...") };
        }

        var added = await RunAsync(connection =>
        {
            // IMMEDIATE takes the write lock before reading the head, so two writers cannot both chain to it.
            using var transaction = connection.BeginTransaction(deferred: false);
            using (var exists = connection.CreateCommand())
            {
                exists.Transaction = transaction;
                exists.CommandText = "SELECT 1 FROM audit_entries WHERE id = $id;";
                exists.Parameters.AddWithValue("$id", Key(record.Id));
                if (exists.ExecuteScalar() is not null)
                {
                    return false;
                }
            }

            long sequence = 0;
            var previous = GenesisHash;
            using (var head = connection.CreateCommand())
            {
                head.Transaction = transaction;
                head.CommandText = "SELECT sequence, entry_hash FROM audit_entries ORDER BY sequence DESC LIMIT 1;";
                using var reader = head.ExecuteReader();
                if (reader.Read())
                {
                    sequence = reader.GetInt64(0) + 1;
                    previous = reader.GetString(1);
                }
            }

            using (var insert = connection.CreateCommand())
            {
                insert.Transaction = transaction;
                insert.CommandText = $"""
                    INSERT INTO audit_entries ({Columns}, sequence, previous_hash, entry_hash)
                    VALUES ($id, $timestamp, $category, $action, $outcome, $client, $clientName, $connection, $connectionName,
                            $error, $message, $digest, $elapsed, $sequence, $previous, $hash);
                    """;
                insert.Parameters.AddWithValue("$id", Key(record.Id));
                insert.Parameters.AddWithValue("$timestamp", record.Timestamp.ToUnixTimeMilliseconds());
                insert.Parameters.AddWithValue("$category", record.Category);
                insert.Parameters.AddWithValue("$action", record.Action);
                insert.Parameters.AddWithValue("$outcome", record.Outcome);
                insert.Parameters.AddWithValue("$client", record.ClientId is { } client ? Key(client) : DBNull.Value);
                insert.Parameters.AddWithValue("$clientName", (object?)record.ClientName ?? DBNull.Value);
                insert.Parameters.AddWithValue("$connection", record.ConnectionId is { } connectionId ? Key(connectionId) : DBNull.Value);
                insert.Parameters.AddWithValue("$connectionName", (object?)record.ConnectionName ?? DBNull.Value);
                insert.Parameters.AddWithValue("$error", (object?)record.ErrorCode ?? DBNull.Value);
                insert.Parameters.AddWithValue("$message", (object?)record.Message ?? DBNull.Value);
                insert.Parameters.AddWithValue("$digest", (object?)record.SqlDigest ?? DBNull.Value);
                insert.Parameters.AddWithValue("$elapsed", record.ElapsedMs);
                insert.Parameters.AddWithValue("$sequence", sequence);
                insert.Parameters.AddWithValue("$previous", previous);
                insert.Parameters.AddWithValue("$hash", ChainHash(record, sequence, previous));
                insert.ExecuteNonQuery();
            }

            transaction.Commit();
            return true;
        }, cancellationToken);

        if (added)
        {
            OnChanged();
            if (_retention is { } retention && Interlocked.Increment(ref _appendsSincePrune) >= AppendsBetweenPrunes)
            {
                Interlocked.Exchange(ref _appendsSincePrune, 0);
                await PruneAsync(retention, cancellationToken);
            }
        }

        return added;
    }

    public Task<IReadOnlyList<McpAuditRecord>> QueryAsync(McpAuditQuery query, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentOutOfRangeException.ThrowIfLessThan(query.Limit, 1);
        return RunAsync<IReadOnlyList<McpAuditRecord>>(connection =>
        {
            using var command = connection.CreateCommand();
            var conditions = new List<string>(3);
            if (query.ClientId is { } client)
            {
                conditions.Add("client_id = $client");
                command.Parameters.AddWithValue("$client", Key(client));
            }

            if (query.Category is { } category)
            {
                conditions.Add("category = $category");
                command.Parameters.AddWithValue("$category", category);
            }

            if (query.Since is { } since)
            {
                conditions.Add("timestamp >= $since");
                command.Parameters.AddWithValue("$since", since.ToUnixTimeMilliseconds());
            }

            command.CommandText = $"SELECT {Columns} FROM audit_entries"
                + (conditions.Count > 0 ? " WHERE " + string.Join(" AND ", conditions) : string.Empty)
                + " ORDER BY sequence DESC LIMIT $limit;";
            command.Parameters.AddWithValue("$limit", query.Limit);
            using var reader = command.ExecuteReader();
            var rows = new List<McpAuditRecord>();
            while (reader.Read())
            {
                rows.Add(Read(reader));
            }

            return rows;
        }, cancellationToken);
    }

    public Task<int> CountAsync(CancellationToken cancellationToken = default) => RunAsync(connection =>
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM audit_entries;";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }, cancellationToken);

    /// <summary>Removes rows older than the window. Returns how many went.</summary>
    public async Task<int> PruneAsync(TimeSpan olderThan, CancellationToken cancellationToken = default)
    {
        var cutoff = (_time.GetUtcNow() - olderThan).ToUnixTimeMilliseconds();
        var removed = await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM audit_entries WHERE timestamp < $cutoff;";
            command.Parameters.AddWithValue("$cutoff", cutoff);
            return command.ExecuteNonQuery();
        }, cancellationToken);

        if (removed > 0)
        {
            OnChanged();
        }

        return removed;
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM audit_entries;";
            return command.ExecuteNonQuery();
        }, cancellationToken);
        OnChanged();
    }

    /// <summary>Walks the rows in sequence and recomputes every link.</summary>
    public Task<McpAuditVerification> VerifyAsync(CancellationToken cancellationToken = default) => RunAsync(connection =>
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"SELECT {Columns}, sequence, previous_hash, entry_hash FROM audit_entries ORDER BY sequence;";
        using var reader = command.ExecuteReader();
        string? expectedPrevious = null;
        long? expectedSequence = null;
        var count = 0;
        while (reader.Read())
        {
            var sequence = reader.GetInt64(13);
            McpAuditRecord record;
            try
            {
                record = Read(reader);
            }
            catch (FormatException)
            {
                return new McpAuditVerification(count, sequence);
            }

            var previous = reader.IsDBNull(14) ? string.Empty : reader.GetString(14);
            var stored = reader.IsDBNull(15) ? string.Empty : reader.GetString(15);
            if (!string.Equals(stored, ChainHash(record, sequence, previous), StringComparison.Ordinal)
                || (expectedPrevious is not null && !string.Equals(previous, expectedPrevious, StringComparison.Ordinal))
                || (expectedSequence is not null && sequence != expectedSequence))
            {
                return new McpAuditVerification(count, sequence);
            }

            expectedPrevious = stored;
            expectedSequence = sequence + 1;
            count++;
        }

        return new McpAuditVerification(count, null);
    }, cancellationToken);

    public void Dispose() => _initGate.Dispose();

    private static string Key(Guid id) => id.ToString("D");

    private static McpAuditRecord Read(SqliteDataReader reader) => new(
        Guid.Parse(reader.GetString(0)),
        DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(1)).ToLocalTime(),
        reader.GetString(2),
        reader.GetString(3),
        reader.GetString(4),
        reader.IsDBNull(5) ? null : Guid.Parse(reader.GetString(5)),
        reader.IsDBNull(6) ? null : reader.GetString(6),
        reader.IsDBNull(7) ? null : Guid.Parse(reader.GetString(7)),
        reader.IsDBNull(8) ? null : reader.GetString(8),
        reader.IsDBNull(9) ? null : reader.GetString(9),
        reader.IsDBNull(10) ? null : reader.GetString(10),
        reader.IsDBNull(11) ? null : reader.GetString(11),
        reader.GetDouble(12));

    private void CreateSchema()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS audit_entries (
                sequence INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                timestamp INTEGER NOT NULL,
                category TEXT NOT NULL,
                action TEXT NOT NULL,
                outcome TEXT NOT NULL,
                client_id TEXT,
                client_name TEXT,
                connection_id TEXT,
                connection_name TEXT,
                error_code TEXT,
                message TEXT,
                sql_digest TEXT,
                elapsed_ms REAL NOT NULL DEFAULT 0,
                previous_hash TEXT NOT NULL,
                entry_hash TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS audit_timestamp ON audit_entries(timestamp);
            CREATE INDEX IF NOT EXISTS audit_client ON audit_entries(client_id, sequence);
            """;
        command.ExecuteNonQuery();
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        return connection;
    }

    private async Task<T> RunAsync<T>(Func<SqliteConnection, T> work, CancellationToken cancellationToken)
    {
        await InitializeAsync(cancellationToken);
        return await Task.Run(() =>
        {
            using var connection = Open();
            return work(connection);
        }, cancellationToken);
    }

    private void OnChanged() => Changed?.Invoke(this, EventArgs.Empty);
}
