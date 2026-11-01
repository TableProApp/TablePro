using System.Globalization;
using System.Text;
using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Sql;

namespace TablePro.Storage.History;

/// <summary>How much history to keep. Null keeps everything along that axis.</summary>
public sealed record QueryHistoryRetention(int? MaxEntries = 10_000, TimeSpan? MaxAge = null);

/// <summary>
/// Executed statements in <c>history.db</c>, a SQLite database in WAL mode with an FTS5 index over the query text.
/// Every call runs on the thread pool, since Microsoft.Data.Sqlite's async methods complete synchronously.
/// </summary>
public sealed class QueryHistoryStore : IDisposable
{
    private const int SchemaVersion = 1;

    // Pruning on every insert would make each one pay for a scan; every few hundred keeps the table near its cap.
    private const int RecordsBetweenPrunes = 200;

    private const string SelectColumns =
        "h.id, h.query, h.connection_id, h.database_name, h.engine, h.schema_name, h.statement_kind, h.source, " +
        "h.executed_at, h.elapsed_ms, h.row_count, h.success, h.error_message";

    private readonly string _connectionString;
    private readonly QueryHistoryRetention? _retention;
    private readonly SemaphoreSlim _initGate = new(1, 1);
    private volatile bool _initialized;
    private int _recordsSincePrune;

    public QueryHistoryStore(AppPaths paths, QueryHistoryRetention? retention = null)
        : this(paths.HistoryDatabase, retention)
    {
    }

    /// <param name="databasePath">The SQLite file, created on first use.</param>
    /// <param name="retention">Applied when the store opens and every few hundred records. Null never prunes on its own.</param>
    public QueryHistoryStore(string databasePath, QueryHistoryRetention? retention = null)
    {
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = Path.GetFullPath(databasePath),
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = true,
            DefaultTimeout = 30,
        }.ToString();
        _retention = retention;
    }

    /// <summary>Fires on a thread-pool thread after entries were added or removed.</summary>
    public event EventHandler? Changed;

    /// <summary>Creates the database and schema. Every other method calls it first, so calling it is optional.</summary>
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

        if (_retention is not null)
        {
            await PruneAsync(_retention, cancellationToken);
        }
    }

    public async Task RecordAsync(QueryHistoryEntry entry, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(entry);
        await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = """
                INSERT INTO history (id, query, connection_id, database_name, engine, schema_name, statement_kind, source,
                                     executed_at, elapsed_ms, row_count, success, error_message)
                VALUES ($id, $query, $connection, $database, $engine, $schema, $kind, $source,
                        $executed, $elapsed, $rows, $success, $error)
                ON CONFLICT(id) DO NOTHING;
                """;
            command.Parameters.AddWithValue("$id", Key(entry.Id));
            command.Parameters.AddWithValue("$query", entry.Query);
            command.Parameters.AddWithValue("$connection", Key(entry.ConnectionId));
            command.Parameters.AddWithValue("$database", (object?)entry.DatabaseName ?? DBNull.Value);
            command.Parameters.AddWithValue("$engine", entry.Engine.ToString());
            command.Parameters.AddWithValue("$schema", (object?)entry.SchemaName ?? DBNull.Value);
            command.Parameters.AddWithValue("$kind", entry.StatementKind.ToString());
            command.Parameters.AddWithValue("$source", SourceName(entry.Source));
            command.Parameters.AddWithValue("$executed", entry.ExecutedAt.ToUnixTimeMilliseconds());
            command.Parameters.AddWithValue("$elapsed", entry.Elapsed.TotalMilliseconds);
            command.Parameters.AddWithValue("$rows", entry.RowCount);
            command.Parameters.AddWithValue("$success", entry.Success ? 1 : 0);
            command.Parameters.AddWithValue("$error", (object?)entry.ErrorMessage ?? DBNull.Value);
            return command.ExecuteNonQuery();
        }, cancellationToken);

        OnChanged();
        if (_retention is not null && Interlocked.Increment(ref _recordsSincePrune) >= RecordsBetweenPrunes)
        {
            Interlocked.Exchange(ref _recordsSincePrune, 0);
            await PruneAsync(_retention, cancellationToken);
        }
    }

    /// <summary>Newest first. Pass the previous page's <see cref="QueryHistoryPage.NextCursor"/> to read on.</summary>
    public Task<QueryHistoryPage> SearchAsync(
        QueryHistoryFilter filter,
        int pageSize = 100,
        QueryHistoryCursor? after = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(filter);
        ArgumentOutOfRangeException.ThrowIfLessThan(pageSize, 1);
        if (filter.Sources is { Count: 0 } || (filter.Since is { } since && filter.Until is { } until && since > until))
        {
            return Task.FromResult(QueryHistoryPage.Empty);
        }

        return RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            var sql = new StringBuilder("SELECT ").Append(SelectColumns).Append(" FROM history h WHERE 1 = 1");
            AppendFilter(sql, command, filter);
            if (after is not null)
            {
                sql.Append(" AND (h.executed_at < $cursorAt OR (h.executed_at = $cursorAt AND h.id < $cursorId))");
                command.Parameters.AddWithValue("$cursorAt", after.ExecutedAt.ToUnixTimeMilliseconds());
                command.Parameters.AddWithValue("$cursorId", Key(after.Id));
            }

            // One extra row says whether another page exists without a second COUNT query.
            sql.Append(" ORDER BY h.executed_at DESC, h.id DESC LIMIT $limit;");
            command.Parameters.AddWithValue("$limit", pageSize + 1);
            command.CommandText = sql.ToString();

            var entries = new List<QueryHistoryEntry>(Math.Min(pageSize + 1, 512));
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    entries.Add(ReadEntry(reader));
                }
            }

            QueryHistoryCursor? next = null;
            if (entries.Count > pageSize)
            {
                entries.RemoveAt(entries.Count - 1);
                var last = entries[^1];
                next = new QueryHistoryCursor(last.ExecutedAt, last.Id);
            }

            return new QueryHistoryPage(entries, next);
        }, cancellationToken);
    }

    public Task<long> CountAsync(QueryHistoryFilter? filter = null, CancellationToken cancellationToken = default) =>
        RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            var sql = new StringBuilder("SELECT COUNT(*) FROM history h WHERE 1 = 1");
            if (filter is not null)
            {
                AppendFilter(sql, command, filter);
            }

            command.CommandText = sql.ToString();
            return (long)command.ExecuteScalar()!;
        }, cancellationToken);

    public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var removed = await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM history WHERE id = $id;";
            command.Parameters.AddWithValue("$id", Key(id));
            return command.ExecuteNonQuery();
        }, cancellationToken);
        if (removed > 0)
        {
            OnChanged();
        }

        return removed > 0;
    }

    /// <summary>Removes a connection's history, or everything when <paramref name="connectionId"/> is null.</summary>
    public async Task<int> ClearAsync(Guid? connectionId, CancellationToken cancellationToken = default)
    {
        var removed = await RunAsync(connection =>
        {
            using var command = connection.CreateCommand();
            if (connectionId is { } id)
            {
                command.CommandText = "DELETE FROM history WHERE connection_id = $connection;";
                command.Parameters.AddWithValue("$connection", Key(id));
            }
            else
            {
                command.CommandText = "DELETE FROM history;";
            }

            return command.ExecuteNonQuery();
        }, cancellationToken);
        if (removed > 0)
        {
            OnChanged();
        }

        return removed;
    }

    /// <summary>Drops entries older than the age limit, then the oldest beyond the count limit. Returns how many went.</summary>
    public async Task<int> PruneAsync(QueryHistoryRetention retention, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(retention);
        var removed = await RunAsync(connection =>
        {
            using var transaction = connection.BeginTransaction();
            var total = 0;
            if (retention.MaxAge is { } maxAge)
            {
                using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = "DELETE FROM history WHERE executed_at < $cutoff;";
                command.Parameters.AddWithValue("$cutoff", (DateTimeOffset.UtcNow - maxAge).ToUnixTimeMilliseconds());
                total += command.ExecuteNonQuery();
            }

            if (retention.MaxEntries is { } maxEntries)
            {
                using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = """
                    DELETE FROM history WHERE seq IN (
                        SELECT seq FROM history ORDER BY executed_at DESC, id DESC LIMIT -1 OFFSET $keep
                    );
                    """;
                command.Parameters.AddWithValue("$keep", Math.Max(0, maxEntries));
                total += command.ExecuteNonQuery();
            }

            transaction.Commit();
            return total;
        }, cancellationToken);
        if (removed > 0)
        {
            OnChanged();
        }

        return removed;
    }

    /// <summary>Releases pooled connections so the database file can be moved or deleted.</summary>
    public void Dispose()
    {
        using (var connection = new SqliteConnection(_connectionString))
        {
            SqliteConnection.ClearPool(connection);
        }

        _initGate.Dispose();
    }

    /// <summary>
    /// FTS5 matches whole tokens, so each word becomes its own quoted prefix term and the terms are ANDed: "sel cust"
    /// finds <c>SELECT * FROM customers</c>. Quoting keeps FTS5's own operators inert, so AND or NOT is searched as text.
    /// </summary>
    internal static string FtsQuery(string searchText)
    {
        var terms = searchText.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (terms.Length == 0)
        {
            return "\"" + searchText.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"*";
        }

        return string.Join(" AND ", terms.Select(t => "\"" + t.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"*"));
    }

    internal static string SourceName(QueryHistorySource source) => source switch
    {
        QueryHistorySource.Explain => "explain",
        QueryHistorySource.TableBrowse => "table_browse",
        QueryHistorySource.RowEdit => "row_edit",
        QueryHistorySource.StructureDdl => "structure_ddl",
        QueryHistorySource.Import => "import",
        QueryHistorySource.Mcp => "mcp",
        _ => "editor",
    };

    private static QueryHistorySource ParseSource(string value) => value switch
    {
        "explain" => QueryHistorySource.Explain,
        "table_browse" => QueryHistorySource.TableBrowse,
        "row_edit" => QueryHistorySource.RowEdit,
        "structure_ddl" => QueryHistorySource.StructureDdl,
        "import" => QueryHistorySource.Import,
        "mcp" => QueryHistorySource.Mcp,
        _ => QueryHistorySource.Editor,
    };

    private static void AppendFilter(StringBuilder sql, SqliteCommand command, QueryHistoryFilter filter)
    {
        if (filter.ConnectionId is { } connectionId)
        {
            sql.Append(" AND h.connection_id = $connection");
            command.Parameters.AddWithValue("$connection", Key(connectionId));
        }

        if (!string.IsNullOrWhiteSpace(filter.SearchText))
        {
            sql.Append(" AND h.seq IN (SELECT rowid FROM history_fts WHERE history_fts MATCH $match)");
            command.Parameters.AddWithValue("$match", FtsQuery(filter.SearchText.Trim()));
        }

        if (filter.Outcome != QueryHistoryOutcome.Any)
        {
            sql.Append(" AND h.success = $success");
            command.Parameters.AddWithValue("$success", filter.Outcome == QueryHistoryOutcome.Succeeded ? 1 : 0);
        }

        if (filter.Since is { } since)
        {
            sql.Append(" AND h.executed_at >= $since");
            command.Parameters.AddWithValue("$since", since.ToUnixTimeMilliseconds());
        }

        if (filter.Until is { } until)
        {
            sql.Append(" AND h.executed_at <= $until");
            command.Parameters.AddWithValue("$until", until.ToUnixTimeMilliseconds());
        }

        if (filter.Sources is { Count: > 0 } sources && sources.Count < Enum.GetValues<QueryHistorySource>().Length)
        {
            sql.Append(" AND h.source IN (");
            var i = 0;
            foreach (var source in sources)
            {
                var name = string.Create(CultureInfo.InvariantCulture, $"$source{i}");
                sql.Append(i == 0 ? string.Empty : ", ").Append(name);
                command.Parameters.AddWithValue(name, SourceName(source));
                i++;
            }

            sql.Append(')');
        }
    }

    private static QueryHistoryEntry ReadEntry(SqliteDataReader reader) => new()
    {
        Id = Guid.Parse(reader.GetString(0)),
        Query = reader.GetString(1),
        ConnectionId = Guid.Parse(reader.GetString(2)),
        DatabaseName = reader.IsDBNull(3) ? null : reader.GetString(3),
        Engine = Enum.TryParse<DatabaseEngine>(reader.GetString(4), out var engine) ? engine : DatabaseEngine.PostgreSql,
        SchemaName = reader.IsDBNull(5) ? null : reader.GetString(5),
        StatementKind = Enum.TryParse<StatementKind>(reader.GetString(6), out var kind) ? kind : StatementKind.Unknown,
        Source = ParseSource(reader.GetString(7)),
        ExecutedAt = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(8)),
        Elapsed = TimeSpan.FromMilliseconds(reader.GetDouble(9)),
        RowCount = reader.GetInt64(10),
        Success = reader.GetInt64(11) != 0,
        ErrorMessage = reader.IsDBNull(12) ? null : reader.GetString(12),
    };

    private static string Key(Guid id) => id.ToString("D");

    private void CreateSchema()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();

        // seq is the rowid alias the FTS index points at. An implicit rowid may be renumbered by VACUUM, which would
        // leave the index pointing at the wrong statements.
        command.CommandText = $"""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS history (
                seq INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                query TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT,
                engine TEXT NOT NULL,
                schema_name TEXT,
                statement_kind TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'editor',
                executed_at INTEGER NOT NULL,
                elapsed_ms REAL NOT NULL,
                row_count INTEGER NOT NULL,
                success INTEGER NOT NULL,
                error_message TEXT
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                query,
                content = 'history',
                content_rowid = 'seq',
                prefix = '2 3 4'
            );
            CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, query) VALUES (new.seq, new.query);
            END;
            CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, query) VALUES ('delete', old.seq, old.query);
            END;
            CREATE INDEX IF NOT EXISTS idx_history_connection_executed ON history(connection_id, executed_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS idx_history_executed ON history(executed_at DESC, id DESC);
            PRAGMA user_version = {SchemaVersion};
            """;
        command.ExecuteNonQuery();
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(_connectionString);
        try
        {
            connection.Open();
            using var pragma = connection.CreateCommand();

            // Safe under WAL: a crash can lose the last commits but never corrupts the file, and each insert skips an fsync.
            pragma.CommandText = "PRAGMA synchronous = NORMAL;";
            pragma.ExecuteNonQuery();
            return connection;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
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
