using System.Diagnostics;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Mcp.Tools;

/// <summary>What a call touched, for the audit log, filled in as the tool learns it.</summary>
internal sealed class McpCallRecord
{
    public Guid? ConnectionId { get; set; }

    public string? ConnectionName { get; set; }

    public string? Sql { get; set; }
}

/// <summary>The nine tools. Stateless: every call reads the saved connections and the open windows again.</summary>
internal sealed class McpTools(IMcpHost host, McpServerOptions options)
{
    private static readonly TimeSpan MetadataTimeout = TimeSpan.FromSeconds(30);

    private const string TransactionNote = "The statement left a transaction open; it was rolled back when the call's connection closed.";

    public Task<string> CallAsync(string name, JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken) => name switch
    {
        "list_connections" => ListConnectionsAsync(arguments, cancellationToken),
        "connect" => ConnectAsync(arguments, record, cancellationToken),
        "list_schemas" => ListSchemasAsync(arguments, record, cancellationToken),
        "list_tables" => ListTablesAsync(arguments, record, cancellationToken),
        "describe_table" => DescribeTableAsync(arguments, record, cancellationToken),
        "get_table_ddl" => GetTableDdlAsync(arguments, record, cancellationToken),
        "browse_table" => BrowseTableAsync(arguments, record, cancellationToken),
        "count_rows" => CountRowsAsync(arguments, record, cancellationToken),
        "execute_query" => ExecuteQueryAsync(arguments, record, cancellationToken),
        _ => throw new McpToolException(McpToolErrorCode.NotFound, $"there is no tool named {name}"),
    };

    private async Task<string> ListConnectionsAsync(JsonElement arguments, CancellationToken cancellationToken)
    {
        _ = new McpArguments(arguments);
        var profiles = await host.GetProfilesAsync(cancellationToken);
        var visible = profiles
            .Where(p => p.ExternalAccess != ExternalAccessLevel.Blocked)
            .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(p => p.Id)
            .ToArray();

        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteStartArray("connections");
            foreach (var profile in visible)
            {
                var session = host.GetOpenSession(profile.Id);
                w.WriteStartObject();
                w.WriteString("id", profile.Id);
                w.WriteString("name", profile.Name);
                w.WriteString("type", profile.Descriptor.DisplayName);
                if (profile.Descriptor.IsFileBased)
                {
                    WriteIfPresent(w, "file", profile.FilePath);
                }
                else
                {
                    w.WriteString("host", profile.Host);
                    w.WriteNumber("port", profile.EffectivePort);
                }

                WriteIfPresent(w, "database", session?.CurrentDatabase ?? profile.Database);
                WriteIfPresent(w, "group", profile.Group);
                w.WriteBoolean("is_open", session is not null);
                w.WriteString("external_access", AccessName(profile.ExternalAccess));
                w.WriteString("safe_mode", SafeModeName(profile.SafeMode));
                w.WriteEndObject();
            }

            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    private async Task<string> ConnectAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id");
        var profile = await ResolveAsync(args.RequiredString("connection_id"), record, cancellationToken);
        var session = host.GetOpenSession(profile.Id);
        if (session is null)
        {
            var opened = await host.OpenSessionAsync(profile.Id, cancellationToken);
            switch (opened.Status)
            {
                case McpOpenStatus.Open when opened.Session is not null:
                    session = opened.Session;
                    break;
                case McpOpenStatus.Connecting:
                    return McpJson.Write(w =>
                    {
                        w.WriteStartObject();
                        w.WriteString("status", "connecting");
                        w.WriteString("connection_id", profile.Id);
                        w.WriteString("message", opened.Message ?? "TablePro is still connecting, or waits for the user in its window. Call connect again in a while.");
                        w.WriteEndObject();
                    });
                default:
                    throw new McpToolException(McpToolErrorCode.NotConnected,
                        opened.Message ?? $"\"{profile.Name}\" did not open; TablePro shows why in its window");
            }
        }

        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("status", "open");
            w.WriteString("connection_id", profile.Id);
            w.WriteString("server_version", session.ServerVersion);
            WriteIfPresent(w, "database", session.CurrentDatabase);
            WriteIfPresent(w, "default_schema", session.DefaultSchema);
            w.WriteString("safe_mode", SafeModeName(profile.SafeMode));
            w.WriteEndObject();
        });
    }

    private async Task<string> ListSchemasAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id");
        var (_, session) = await OpenAsync(args, record, cancellationToken);
        var schemas = await Bounded(ct => session.GetSchemasAsync(ct), cancellationToken);
        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            WriteIfPresent(w, "default_schema", session.DefaultSchema);
            w.WriteStartArray("schemas");
            foreach (var schema in schemas)
            {
                w.WriteStringValue(schema);
            }

            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    private async Task<string> ListTablesAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id", "schema");
        var (_, session) = await OpenAsync(args, record, cancellationToken);
        var schema = args.OptionalString("schema") ?? session.DefaultSchema;
        var objects = await Bounded(ct => session.GetObjectsAsync(schema, ct), cancellationToken);
        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            WriteIfPresent(w, "schema", schema);
            w.WriteStartArray("tables");
            foreach (var obj in objects.Where(o => o.HasRows))
            {
                w.WriteStartObject();
                w.WriteString("name", obj.Name.Name);
                WriteIfPresent(w, "schema", obj.Name.Schema);
                w.WriteString("kind", obj.Kind switch
                {
                    ObjectKind.View => "view",
                    ObjectKind.MaterializedView => "materialized_view",
                    _ => "table",
                });
                if (obj.RowEstimate is { } estimate and >= 0)
                {
                    w.WriteNumber("row_estimate", estimate);
                }

                WriteIfPresent(w, "comment", obj.Comment);
                w.WriteEndObject();
            }

            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    private async Task<string> DescribeTableAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id", "table", "schema");
        var (_, session) = await OpenAsync(args, record, cancellationToken);
        var structure = await StructureAsync(session, TableName(args, session), cancellationToken);
        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("table", structure.Table.Name);
            WriteIfPresent(w, "schema", structure.Table.Schema);
            w.WriteStartArray("columns");
            foreach (var column in structure.Columns.OrderBy(c => c.Ordinal))
            {
                w.WriteStartObject();
                w.WriteString("name", column.Name);
                w.WriteString("type", column.DataType);
                w.WriteBoolean("nullable", column.IsNullable);
                w.WriteBoolean("primary_key", column.IsPrimaryKey);
                if (column.IsIdentity)
                {
                    w.WriteBoolean("identity", true);
                }

                WriteIfPresent(w, "default", column.DefaultValue);
                WriteIfPresent(w, "comment", column.Comment);
                w.WriteEndObject();
            }

            w.WriteEndArray();
            WriteStrings(w, "primary_key", structure.PrimaryKey);
            w.WriteStartArray("indexes");
            foreach (var index in structure.Indexes)
            {
                w.WriteStartObject();
                w.WriteString("name", index.Name);
                WriteStrings(w, "columns", index.Columns);
                w.WriteBoolean("unique", index.IsUnique);
                w.WriteBoolean("primary", index.IsPrimary);
                WriteIfPresent(w, "method", index.Method);
                w.WriteEndObject();
            }

            w.WriteEndArray();
            w.WriteStartArray("foreign_keys");
            foreach (var fk in structure.ForeignKeys)
            {
                w.WriteStartObject();
                w.WriteString("name", fk.Name);
                WriteStrings(w, "columns", fk.Columns);
                WriteIfPresent(w, "referenced_schema", fk.ReferencedTable.Schema);
                w.WriteString("referenced_table", fk.ReferencedTable.Name);
                WriteStrings(w, "referenced_columns", fk.ReferencedColumns);
                WriteIfPresent(w, "on_update", fk.OnUpdate);
                WriteIfPresent(w, "on_delete", fk.OnDelete);
                w.WriteEndObject();
            }

            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    private async Task<string> GetTableDdlAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id", "table", "schema");
        var (_, session) = await OpenAsync(args, record, cancellationToken);
        var name = TableName(args, session);

        // A view's definition is read differently from a table's, so the kind comes from the catalog.
        var objects = await Bounded(ct => session.GetObjectsAsync(name.Schema, ct), cancellationToken);
        var obj = objects.FirstOrDefault(o => o.HasRows && string.Equals(o.Name.Name, name.Name, StringComparison.Ordinal))
            ?? objects.FirstOrDefault(o => o.HasRows && string.Equals(o.Name.Name, name.Name, StringComparison.OrdinalIgnoreCase))
            ?? throw NoSuchTable(name);
        var ddl = await Bounded(ct => session.GetDefinitionAsync(obj, ct), cancellationToken);
        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("table", obj.Name.Name);
            WriteIfPresent(w, "schema", obj.Name.Schema);
            w.WriteString("ddl", ddl);
            w.WriteEndObject();
        });
    }

    private async Task<string> BrowseTableAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id", "table", "schema", "filters", "logic", "sort", "limit", "offset");
        var limit = args.Int("limit", options.DefaultRows, 1, options.MaxRows);
        var offset = args.Int("offset", 0, 0, int.MaxValue);
        var (_, session) = await OpenAsync(args, record, cancellationToken);
        var structure = await StructureAsync(session, TableName(args, session), cancellationToken);
        var filter = BuildFilter(args, structure);
        var sort = BuildSort(args, structure);
        var started = Stopwatch.GetTimestamp();
        var request = new BrowseRequest(structure.Table, filter, sort, offset, limit);
        var result = await Bounded(ct => session.BrowseAsync(request, ct), cancellationToken);
        var elapsed = Stopwatch.GetElapsedTime(started);
        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("table", structure.Table.Name);
            WriteIfPresent(w, "schema", structure.Table.Schema);
            w.WriteNumber("offset", offset);
            w.WritePropertyName("result");
            McpJson.WriteResultSet(w, result, limit, options.MaxCellChars);
            w.WriteNumber("elapsed_ms", (long)elapsed.TotalMilliseconds);
            w.WriteEndObject();
        });
    }

    private async Task<string> CountRowsAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id", "table", "schema", "filters", "logic");
        var (_, session) = await OpenAsync(args, record, cancellationToken);
        var structure = await StructureAsync(session, TableName(args, session), cancellationToken);
        var filter = BuildFilter(args, structure);
        var count = await Bounded(ct => session.CountAsync(structure.Table, filter, ct), cancellationToken);
        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("table", structure.Table.Name);
            WriteIfPresent(w, "schema", structure.Table.Schema);
            w.WriteNumber("row_count", count);
            w.WriteEndObject();
        });
    }

    private async Task<string> ExecuteQueryAsync(JsonElement arguments, McpCallRecord record, CancellationToken cancellationToken)
    {
        var args = new McpArguments(arguments, "connection_id", "query", "max_rows", "timeout_seconds");
        var query = args.RequiredString("query");
        var maxRows = args.Int("max_rows", options.DefaultRows, 1, options.MaxRows);
        var timeoutSeconds = args.Int("timeout_seconds", options.DefaultTimeoutSeconds, 1, options.MaxTimeoutSeconds);
        var (profile, session) = await OpenAsync(args, record, cancellationToken);
        record.Sql = query;

        var statement = McpStatementGate.Analyze(query, session.Dialect, options.MaxQueryBytes);
        record.Sql = statement.Sql;
        if (McpStatementGate.Refusal(profile, statement) is { } refusal)
        {
            throw refusal;
        }

        if (!statement.IsRead)
        {
            var approved = await host.RequestWriteApprovalAsync(new McpWriteApprovalRequest(profile, statement.Sql, statement.Kind, statement.IsDestructive), cancellationToken);
            if (!approved)
            {
                throw new McpToolException(McpToolErrorCode.UserCancelled, "the user declined the statement in TablePro");
            }

            // A level the user changed while the question was open applies to the answer.
            profile = await ResolveAsync(profile.Id.ToString(), record, cancellationToken);
            if (McpStatementGate.Refusal(profile, statement) is { } late)
            {
                throw late;
            }
        }

        var executedAt = DateTimeOffset.Now;
        var started = Stopwatch.GetTimestamp();
        Executed executed;
        try
        {
            executed = await RunAsync(session, profile, statement, maxRows, timeoutSeconds, cancellationToken);
        }
        catch (McpToolException ex)
        {
            await RecordAsync(profile, statement.Sql, executedAt, Stopwatch.GetElapsedTime(started), null, ex.Message, ex.Code == McpToolErrorCode.UserCancelled);
            throw;
        }

        var elapsed = Stopwatch.GetElapsedTime(started);
        await RecordAsync(profile, statement.Sql, executedAt, elapsed, executed.RowsAffected, null, cancelled: false);

        return McpJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("statement_kind", statement.Kind.ToString().ToLowerInvariant());
            w.WriteStartArray("result_sets");
            foreach (var set in executed.Sets)
            {
                McpJson.WriteResultSet(w, set, maxRows, options.MaxCellChars);
            }

            w.WriteEndArray();
            if (executed.OmittedSets > 0)
            {
                w.WriteNumber("result_sets_omitted", executed.OmittedSets);
            }

            if (executed.RowsAffected is { } affected)
            {
                w.WriteNumber("rows_affected", affected);
            }

            w.WriteNumber("elapsed_ms", (long)elapsed.TotalMilliseconds);
            WriteStrings(w, "messages", executed.Messages, skipWhenEmpty: true);
            if (executed.LeftTransactionOpen)
            {
                WriteStrings(w, "notes", [TransactionNote]);
            }

            w.WriteEndObject();
        });
    }

    private sealed record Executed(IReadOnlyList<ResultSet> Sets, int OmittedSets, int? RowsAffected, IReadOnlyList<string> Messages, bool LeftTransactionOpen);

    /// <summary>
    /// Runs the statement on a connection of its own, closed after the call, so nothing it sets or leaves open reaches
    /// an editor tab. A read runs inside the engine's read-only mode where it has one.
    /// </summary>
    private async Task<Executed> RunAsync(IDatabaseSession session, ConnectionProfile profile, GatedStatement statement, int maxRows, int timeoutSeconds, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds) + options.TimeoutGrace);
        var token = deadline.Token;
        var guard = statement.IsRead ? ReadGuard.For(profile.Engine) : null;
        // The driver cancels the command once it has read RowLimit rows. That is right for a read, but cancelling an
        // approved INSERT ... RETURNING mid-stream would roll it back, so a write reads everything and the answer trims.
        var rowLimit = statement.IsRead ? maxRows : int.MaxValue;
        var executeOptions = new ExecuteOptions(RowLimit: rowLimit, CommandTimeoutSeconds: timeoutSeconds, StopOnError: true);
        IReadOnlyList<string> statements = guard is null ? [statement.Sql] : [guard.Begin, statement.Sql];

        var results = new List<StatementResult>(statements.Count);
        IQueryChannel channel;
        try
        {
            channel = await session.OpenChannelAsync(token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw TimedOut(timeoutSeconds);
        }

        await using (channel)
        {
            try
            {
                await foreach (var result in channel.ExecuteAsync(statements, executeOptions, token))
                {
                    results.Add(result);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw new McpToolException(McpToolErrorCode.UserCancelled, "the request was cancelled");
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested)
            {
                throw TimedOut(timeoutSeconds);
            }
            catch (OperationCanceledException)
            {
                throw new McpToolException(McpToolErrorCode.QueryFailed, "the driver cancelled the statement");
            }
            finally
            {
                if (guard is not null)
                {
                    await EndGuardAsync(channel, guard, executeOptions);
                }
            }
        }

        if (guard is not null && results is [{ Succeeded: false } begin, ..])
        {
            throw new McpToolException(McpToolErrorCode.QueryFailed, $"the read-only transaction did not start: {begin.Error}");
        }

        var own = results.Count == statements.Count ? results[^1] : null;
        if (own is null || !own.Succeeded)
        {
            if (deadline.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw TimedOut(timeoutSeconds);
            }

            if (cancellationToken.IsCancellationRequested)
            {
                throw new McpToolException(McpToolErrorCode.UserCancelled, "the request was cancelled");
            }

            throw new McpToolException(McpToolErrorCode.QueryFailed, own?.Error ?? "the statement returned no result");
        }

        var sets = own.ResultSets;
        var kept = sets.Count > options.MaxResultSets ? sets.Take(options.MaxResultSets).ToArray() : sets;
        var affected = own.RecordsAffected >= 0 && (sets.Count == 0 || !statement.IsRead) ? own.RecordsAffected : (int?)null;
        return new Executed(kept, sets.Count - kept.Count, affected, own.Messages ?? [], LeftTransactionOpen(statement));
    }

    private static async Task EndGuardAsync(IQueryChannel channel, ReadGuard guard, ExecuteOptions executeOptions)
    {
        // Runs even when the call was cancelled, so its own short deadline replaces the call's token.
        using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            await foreach (var _ in channel.ExecuteAsync([guard.End], executeOptions with { StopOnError = false }, cleanup.Token))
            {
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException or System.Data.Common.DbException)
        {
            // The channel closes right after, which ends the transaction anyway; query_only goes with the pooled connection's reset.
        }
    }

    private static bool LeftTransactionOpen(GatedStatement statement)
    {
        if (statement.Kind != StatementKind.Transaction)
        {
            return false;
        }

        var first = statement.Sql.AsSpan().TrimStart();
        return first.StartsWith("BEGIN", StringComparison.OrdinalIgnoreCase) || first.StartsWith("START", StringComparison.OrdinalIgnoreCase);
    }

    private async ValueTask RecordAsync(ConnectionProfile profile, string sql, DateTimeOffset executedAt, TimeSpan elapsed, int? rowsAffected, string? error, bool cancelled)
    {
        try
        {
            await host.RecordHistoryAsync(new McpHistoryEntry(profile.Id, profile.Name, sql, executedAt, elapsed, rowsAffected, cancelled ? null : error, cancelled), CancellationToken.None);
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            // History is a convenience; a failed write there must not turn a statement that ran into an error.
        }
    }

    private async Task<ConnectionProfile> ResolveAsync(string id, McpCallRecord record, CancellationToken cancellationToken)
    {
        if (!Guid.TryParse(id, out var guid))
        {
            throw new McpToolException(McpToolErrorCode.NotFound, $"no connection has the id {id}");
        }

        var profiles = await host.GetProfilesAsync(cancellationToken);
        var profile = profiles.FirstOrDefault(p => p.Id == guid);

        // A blocked connection answers exactly like a missing one, so a client cannot learn it exists.
        if (profile is null || profile.ExternalAccess == ExternalAccessLevel.Blocked)
        {
            throw new McpToolException(McpToolErrorCode.NotFound, $"no connection has the id {id}");
        }

        record.ConnectionId = profile.Id;
        record.ConnectionName = profile.Name;
        return profile;
    }

    private async Task<(ConnectionProfile Profile, IDatabaseSession Session)> OpenAsync(McpArguments args, McpCallRecord record, CancellationToken cancellationToken)
    {
        var profile = await ResolveAsync(args.RequiredString("connection_id"), record, cancellationToken);
        var session = host.GetOpenSession(profile.Id)
            ?? throw new McpToolException(McpToolErrorCode.NotConnected, $"\"{profile.Name}\" is not open in TablePro; call connect first");
        return (profile, session);
    }

    private static ObjectName TableName(McpArguments args, IDatabaseSession session) =>
        new(args.OptionalString("schema") ?? session.DefaultSchema, args.RequiredString("table"));

    private static async Task<TableStructure> StructureAsync(IDatabaseSession session, ObjectName name, CancellationToken cancellationToken)
    {
        var structure = await Bounded(ct => session.GetStructureAsync(name, ct), cancellationToken);
        return structure.Columns.Count == 0 ? throw NoSuchTable(name) : structure;
    }

    private static McpToolException NoSuchTable(ObjectName name) =>
        new(McpToolErrorCode.NotFound, $"there is no table or view named {name}; list_tables shows what there is");

    private static BrowseFilter BuildFilter(McpArguments args, TableStructure structure)
    {
        var rules = new List<FilterRule>();
        foreach (var item in args.Array("filters"))
        {
            var filter = new McpArguments(item, "column", "operator", "value", "values");
            var column = ColumnName(filter.RequiredString("column"), structure);
            var op = ParseOperator(filter.RequiredString("operator"));
            var values = filter.Array("values").Select(v => v.ValueKind == JsonValueKind.String
                ? v.GetString() ?? string.Empty
                : throw McpToolException.Invalid("values must hold strings")).ToArray();
            var value = filter.OptionalString("value");
            rules.Add(op switch
            {
                FilterOperator.In or FilterOperator.NotIn => new FilterRule(column, op, InList(values)),
                FilterOperator.Between => values.Length == 2
                    ? new FilterRule(column, op, values[0], values[1])
                    : throw McpToolException.Invalid("between takes values with the low and the high bound"),
                _ when op.TakesValue() => new FilterRule(column, op, value ?? throw McpToolException.Invalid($"{OperatorName(op)} takes a value")),
                _ => new FilterRule(column, op),
            });
        }

        var logic = args.OptionalString("logic") ?? "and";
        var matchAll = logic switch
        {
            "and" => true,
            "or" => false,
            _ => throw McpToolException.Invalid("logic must be and or or"),
        };

        // RawWhere stays null: a client never writes SQL into the WHERE clause, only bound values.
        return new BrowseFilter(rules, RawWhere: null, MatchAll: matchAll);
    }

    private static string InList(string[] values)
    {
        if (values.Length == 0)
        {
            throw McpToolException.Invalid("in and not_in take a non-empty values list");
        }

        // The filter strip's IN takes comma-separated text, so a value holding a comma cannot be told apart.
        return values.Any(v => v.Contains(',', StringComparison.Ordinal))
            ? throw McpToolException.Invalid("an in or not_in value cannot contain a comma")
            : string.Join(',', values);
    }

    private static List<SortColumn> BuildSort(McpArguments args, TableStructure structure)
    {
        var sort = new List<SortColumn>();
        foreach (var item in args.Array("sort"))
        {
            var entry = new McpArguments(item, "column", "direction");
            var column = ColumnName(entry.RequiredString("column"), structure);
            var descending = (entry.OptionalString("direction") ?? "ascending") switch
            {
                "ascending" => false,
                "descending" => true,
                _ => throw McpToolException.Invalid("direction must be ascending or descending"),
            };
            sort.Add(new SortColumn(column, descending));
        }

        return sort;
    }

    /// <summary>Only the table's own columns pass, spelled as the catalog spells them.</summary>
    private static string ColumnName(string name, TableStructure structure) =>
        structure.Columns.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.Ordinal))?.Name
        ?? structure.Columns.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase))?.Name
        ?? throw McpToolException.Invalid($"{structure.Table} has no column named {name}");

    private static FilterOperator ParseOperator(string name) => name switch
    {
        "eq" => FilterOperator.Equals,
        "not_eq" => FilterOperator.NotEquals,
        "gt" => FilterOperator.GreaterThan,
        "gt_eq" => FilterOperator.GreaterOrEqual,
        "lt" => FilterOperator.LessThan,
        "lt_eq" => FilterOperator.LessOrEqual,
        "contains" => FilterOperator.Contains,
        "not_contains" => FilterOperator.NotContains,
        "starts_with" => FilterOperator.StartsWith,
        "ends_with" => FilterOperator.EndsWith,
        "is_null" => FilterOperator.IsNull,
        "is_not_null" => FilterOperator.IsNotNull,
        "is_empty" => FilterOperator.IsEmpty,
        "is_not_empty" => FilterOperator.IsNotEmpty,
        "in" => FilterOperator.In,
        "not_in" => FilterOperator.NotIn,
        "between" => FilterOperator.Between,
        _ => throw McpToolException.Invalid($"unknown operator {name}"),
    };

    private static string OperatorName(FilterOperator op) => op.ToString().ToLowerInvariant();

    private static async Task<T> Bounded<T>(Func<CancellationToken, Task<T>> read, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(MetadataTimeout);
        try
        {
            return await read(deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new McpToolException(McpToolErrorCode.Timeout, $"the server did not answer within {MetadataTimeout.TotalSeconds:0} seconds");
        }
        catch (OperationCanceledException)
        {
            throw new McpToolException(McpToolErrorCode.UserCancelled, "the request was cancelled");
        }
        catch (System.Data.Common.DbException ex)
        {
            throw new McpToolException(McpToolErrorCode.QueryFailed, ex.Message);
        }
    }

    private static McpToolException TimedOut(int seconds) =>
        new(McpToolErrorCode.Timeout, $"the statement ran past {seconds} seconds and was stopped");

    private static string AccessName(ExternalAccessLevel level) => level switch
    {
        ExternalAccessLevel.ReadWrite => "read_write",
        ExternalAccessLevel.ReadOnly => "read_only",
        _ => "blocked",
    };

    private static string SafeModeName(SafeModeLevel level) => level switch
    {
        SafeModeLevel.Silent => "silent",
        SafeModeLevel.Alert => "alert",
        SafeModeLevel.AlertFull => "alert_full",
        SafeModeLevel.SafeMode => "safe_mode",
        SafeModeLevel.SafeModeFull => "safe_mode_full",
        SafeModeLevel.ReadOnly => "read_only",
        _ => level.ToString(),
    };

    private static void WriteIfPresent(Utf8JsonWriter writer, string name, string? value)
    {
        if (!string.IsNullOrEmpty(value))
        {
            writer.WriteString(name, value);
        }
    }

    private static void WriteStrings(Utf8JsonWriter writer, string name, IReadOnlyList<string> values, bool skipWhenEmpty = false)
    {
        if (skipWhenEmpty && values.Count == 0)
        {
            return;
        }

        writer.WriteStartArray(name);
        foreach (var value in values)
        {
            writer.WriteStringValue(value);
        }

        writer.WriteEndArray();
    }
}
