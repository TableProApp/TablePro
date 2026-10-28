using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.SurrealDb;

/// <summary>SurrealDB over its HTTP <c>/sql</c> endpoint.</summary>
public sealed class SurrealDbDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.SurrealDb];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var handler = HttpEndpoint.CreateHandler(request.Profile.SslMode, request.Profile.ConnectTimeoutSeconds);
        return await SurrealDbSession.ConnectAsync(request, handler, cancellationToken);
    }
}

/// <summary>Where a connection points: the namespace and database, and how it signs in.</summary>
internal sealed record SurrealSettings(string? Namespace, string? Database, string AuthLevel)
{
    public const string NamespaceOption = "namespace";
    public const string DatabaseOption = "database";
    public const string AuthLevelOption = "authLevel";

    /// <summary>
    /// The namespace comes from its option or from the Database field before a slash (<c>ns/db</c>). Without either,
    /// the Database field names the namespace, since that is the level a SurrealDB login starts from.
    /// </summary>
    public static SurrealSettings From(ConnectionProfile profile, string? database)
    {
        var options = profile.AdditionalOptions;
        var ns = options.TryGetValue(NamespaceOption, out var n) && !string.IsNullOrWhiteSpace(n) ? n.Trim() : null;
        var db = options.TryGetValue(DatabaseOption, out var d) && !string.IsNullOrWhiteSpace(d) ? d.Trim() : null;
        var field = database?.Trim();
        if (!string.IsNullOrEmpty(field))
        {
            var slash = field.IndexOf('/', StringComparison.Ordinal);
            if (slash >= 0)
            {
                ns ??= field[..slash].Trim();
                db = field[(slash + 1)..].Trim();
            }
            else if (ns is not null)
            {
                db = field;
            }
            else
            {
                ns = field;
            }
        }

        var level = options.TryGetValue(AuthLevelOption, out var l) && !string.IsNullOrWhiteSpace(l) ? l.Trim().ToLowerInvariant() : "root";
        return new SurrealSettings(string.IsNullOrEmpty(ns) ? null : ns, string.IsNullOrEmpty(db) ? null : db, level);
    }

    /// <summary>
    /// Basic auth signs in a root user as it is. A namespace or database user also names its level with the
    /// <c>Surreal-Auth-NS</c> and <c>Surreal-Auth-DB</c> headers, and a token goes as a bearer.
    /// </summary>
    public void Apply(HttpRequestHeaders headers, string? username, string? password)
    {
        if (AuthLevel == "token")
        {
            if (!string.IsNullOrEmpty(password))
            {
                headers.Authorization = new AuthenticationHeaderValue("Bearer", password);
            }

            return;
        }

        if (!string.IsNullOrEmpty(username))
        {
            headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{username}:{password}")));
        }

        if (AuthLevel is "namespace" or "database" && Namespace is not null)
        {
            headers.TryAddWithoutValidation("Surreal-Auth-NS", Namespace);
        }

        if (AuthLevel == "database" && Database is not null)
        {
            headers.TryAddWithoutValidation("Surreal-Auth-DB", Database);
        }
    }
}

/// <summary>One statement's answer from <c>/sql</c>.</summary>
internal readonly record struct SurrealResult(bool Ok, JsonElement Value, string? Error);

/// <summary>
/// A connected SurrealDB. Namespaces are the databases of the switcher, a namespace's databases are its schemas, and
/// tables are collections. Each request names its namespace and database in headers, so nothing depends on session
/// state on the server.
/// </summary>
internal sealed class SurrealDbSession : IDatabaseSession
{
    internal const int SampleSize = 100;

    private const string RowCountMarker = "tablepro:row-count";

    private readonly HttpTransport _transport;
    private readonly SurrealSettings _settings;
    private readonly ConcurrentDictionary<(string? Database, string Table), IReadOnlyDictionary<string, SurrealKind>> _kinds = new();

    private SurrealDbSession(ConnectionProfile profile, HttpTransport transport, SurrealSettings settings, string version)
    {
        Profile = profile;
        _transport = transport;
        _settings = settings;
        ServerVersion = version;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => SurrealQlDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => _settings.Namespace;

    public string? DefaultSchema => _settings.Database;

    public static async Task<SurrealDbSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler handler, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var profile = request.Profile;
        var settings = SurrealSettings.From(profile, request.Database);
        var transport = new HttpTransport(handler, HttpEndpoint.BaseUri(request.Host, request.Port, profile.SslMode != SslMode.Disabled));
        try
        {
            transport.DefaultHeaders.Accept.ParseAdd("application/json");
            settings.Apply(transport.DefaultHeaders, profile.Username, request.Password);
            var version = await transport.ProbeAsync(profile.SslMode, request.Host, profile.ConnectTimeoutSeconds, async token =>
            {
                var reply = await transport.SendAsync(HttpMethod.Get, "/version", (string?)null, token);
                var text = reply.IsSuccess ? reply.Text.Trim() : string.Empty;
                return text.StartsWith("surrealdb-", StringComparison.OrdinalIgnoreCase) ? text["surrealdb-".Length..] : text;
            }, cancellationToken);
            var session = new SurrealDbSession(profile, transport, settings, version);

            // /version answers without credentials, so the login is checked by a statement.
            await session.QueryValueAsync("RETURN 1;", settings.Database, cancellationToken);
            return session;
        }
        catch
        {
            transport.Dispose();
            throw;
        }
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        await QueryValueAsync("RETURN 1;", _settings.Database, cancellationToken);
    }

    /// <summary>The namespaces a root user sees; anyone else sees the one they signed in to.</summary>
    public async Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken)
    {
        await Yield();
        try
        {
            using var info = await QueryAsync("INFO FOR ROOT;", null, cancellationToken, noNamespace: true);
            return Names(SingleValue(info.Results), "namespaces");
        }
        catch (ServerRequestException)
        {
            return _settings.Namespace is null ? [] : [_settings.Namespace];
        }
    }

    public async Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken)
    {
        await Yield();
        if (_settings.Namespace is null)
        {
            return [];
        }

        try
        {
            using var info = await QueryAsync("INFO FOR NS;", null, cancellationToken);
            return Names(SingleValue(info.Results), "databases");
        }
        catch (ServerRequestException)
        {
            return _settings.Database is null ? [] : [_settings.Database];
        }
    }

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var database = schema ?? _settings.Database;
        using var info = await QueryAsync("INFO FOR DB;", database, cancellationToken);
        var objects = new List<DatabaseObject>();
        foreach (var (name, definition) in Entries(SingleValue(info.Results), "tables"))
        {
            var upper = definition.ToUpperInvariant();
            var kind = upper.Contains("TYPE RELATION", StringComparison.Ordinal) ? "relation"
                : upper.Contains("SCHEMAFULL", StringComparison.Ordinal) ? "schemafull" : "schemaless";
            objects.Add(new DatabaseObject(new ObjectName(database, name), ObjectKind.Collection, null, kind));
        }

        return objects;
    }

    /// <summary>
    /// Declared fields come from <c>INFO FOR TABLE</c>; a schemaless table also shows the fields a sample of its rows
    /// holds. Both go in one request.
    /// </summary>
    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var database = table.Schema ?? _settings.Database;
        var ident = SurrealQl.Ident(table.Name);
        using var response = await QueryAsync(
            string.Create(CultureInfo.InvariantCulture, $"INFO FOR TABLE {ident};\nSELECT * FROM {ident} LIMIT {SampleSize};"),
            database,
            cancellationToken);
        var (columns, kinds, indexes) = Describe(table.Name, response.Results[0].Value, response.Results.Count > 1 ? response.Results[1].Value : default);
        _kinds[(database, table.Name)] = kinds;
        return new TableStructure(table, columns, indexes, [], []);
    }

    internal static (List<ColumnInfo> Columns, Dictionary<string, SurrealKind> Kinds, List<IndexInfo> Indexes) Describe(string table, JsonElement info, JsonElement sample)
    {
        var columns = new List<ColumnInfo> { new("id", "record", false, null, true, false, 0) };
        var kinds = new Dictionary<string, SurrealKind>(StringComparer.Ordinal);
        var fields = Entries(info, "fields").ToArray();
        var isRelation = sample.ValueKind == JsonValueKind.Array && sample.EnumerateArray().Any(r => r.ValueKind == JsonValueKind.Object && r.TryGetProperty("in", out _) && r.TryGetProperty("out", out _));
        if (isRelation)
        {
            columns.Add(new ColumnInfo("in", "record", false, null, false, false, columns.Count));
            columns.Add(new ColumnInfo("out", "record", false, null, false, false, columns.Count));
        }

        foreach (var (name, definition) in fields)
        {
            // A nested field (a.b, tags[*]) lives inside its parent's cell.
            if (name.Contains('.', StringComparison.Ordinal) || name.Contains('[', StringComparison.Ordinal) || name is "id" or "in" or "out")
            {
                continue;
            }

            var kind = SurrealKind.Parse(KindOf(definition));
            kinds[name] = kind;
            columns.Add(new ColumnInfo(name, kind.Raw.Length == 0 ? "any" : kind.Raw, kind.IsOptional, Default(definition), false, false, columns.Count));
        }

        if (sample.ValueKind == JsonValueKind.Array)
        {
            var seen = new HashSet<string>(columns.Select(c => c.Name), StringComparer.Ordinal);
            foreach (var row in sample.EnumerateArray().Where(r => r.ValueKind == JsonValueKind.Object))
            {
                foreach (var property in row.EnumerateObject())
                {
                    if (seen.Add(property.Name))
                    {
                        var inferred = Infer(property.Value);
                        kinds[property.Name] = new SurrealKind(inferred, true, null, inferred);
                        columns.Add(new ColumnInfo(property.Name, inferred, true, null, false, false, columns.Count, "not declared"));
                    }
                }
            }
        }

        var indexes = new List<IndexInfo> { new("id", ["id"], true, true) };
        foreach (var (name, definition) in Entries(info, "indexes"))
        {
            indexes.Add(new IndexInfo(name, IndexColumns(definition), definition.Contains(" UNIQUE", StringComparison.OrdinalIgnoreCase), false));
        }

        return (columns, kinds, indexes);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var database = obj.Name.Schema ?? _settings.Database;
        using var response = await QueryAsync($"INFO FOR DB;\nINFO FOR TABLE {SurrealQl.Ident(obj.Name.Name)};", database, cancellationToken);
        var lines = new List<string>();
        foreach (var (name, definition) in Entries(response.Results[0].Value, "tables"))
        {
            if (name == obj.Name.Name)
            {
                lines.Add(Terminated(definition));
            }
        }

        foreach (var section in new[] { "fields", "indexes", "events" })
        {
            lines.AddRange(Entries(response.Results[1].Value, section).Select(e => Terminated(e.Definition)));
        }

        return string.Join("\n", lines);

        static string Terminated(string definition) => definition.TrimEnd().EndsWith(';') ? definition.TrimEnd() : definition.TrimEnd() + ";";
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var database = request.Table.Schema ?? _settings.Database;
        var kinds = await KindsAsync(request.Table, cancellationToken);
        var statement = BuildBrowse(request, kinds);
        using var response = await QueryAsync(statement, database, cancellationToken);
        var value = response.Results[^1].Value;
        var table = new DocumentTable();
        table.Declare("id", "record", typeof(string));
        foreach (var (name, kind) in kinds)
        {
            table.Declare(name, kind.Raw.Length == 0 ? "any" : kind.Raw, kind.ClrType);
        }

        if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var row in value.EnumerateArray())
            {
                table.NewRow();
                table.SetTopLevel(row);
            }
        }

        return table.Build();
    }

    /// <summary>The page query, with every filter value bound as a variable set ahead of the SELECT.</summary>
    internal static string BuildBrowse(BrowseRequest request, IReadOnlyDictionary<string, SurrealKind> kinds)
    {
        var parameters = new SurrealParams();
        var sql = new StringBuilder("SELECT * FROM ").Append(SurrealQl.Ident(request.Table.Name));
        if (SurrealFilter.Where(request.Filter, request.Table.Name, kinds, parameters) is { } where)
        {
            sql.Append(" WHERE ").Append(where);
        }

        // Ordering by id last keeps pages stable when the chosen columns tie.
        sql.Append(" ORDER BY ");
        foreach (var sort in request.Sort.Where(s => s.Column != "id"))
        {
            sql.Append(SurrealQl.Ident(sort.Column)).Append(sort.Descending ? " DESC, " : " ASC, ");
        }

        var idSort = request.Sort.FirstOrDefault(s => s.Column == "id");
        sql.Append(idSort.Column is not null && idSort.Descending ? "id DESC" : "id ASC");
        sql.Append(CultureInfo.InvariantCulture, $" LIMIT {Math.Max(1, request.Limit)} START {Math.Max(0, request.Offset)};");
        return parameters.Prefix + sql;
    }

    internal static string BuildCount(ObjectName table, BrowseFilter filter, IReadOnlyDictionary<string, SurrealKind> kinds)
    {
        var parameters = new SurrealParams();
        var sql = new StringBuilder("SELECT count() AS total FROM ").Append(SurrealQl.Ident(table.Name));
        if (SurrealFilter.Where(filter, table.Name, kinds, parameters) is { } where)
        {
            sql.Append(" WHERE ").Append(where);
        }

        sql.Append(" GROUP ALL;");
        return parameters.Prefix + sql;
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var kinds = await KindsAsync(table, cancellationToken);
        using var response = await QueryAsync(BuildCount(table, filter, kinds), table.Schema ?? _settings.Database, cancellationToken);
        var value = response.Results[^1].Value;

        // GROUP ALL over no rows answers an empty list rather than a zero.
        return value.ValueKind == JsonValueKind.Array && value.GetArrayLength() > 0 && value[0].TryGetProperty("total", out var total) ? total.GetInt64() : 0;
    }

    /// <summary>
    /// Every change runs in one transaction. An update or delete first checks its record exists and throws otherwise,
    /// which cancels the whole transaction, since an UPDATE of a missing record would create it on SurrealDB 1.
    /// </summary>
    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        if (changes.Count == 0)
        {
            return 0;
        }

        var kinds = await KindsAsync(table, cancellationToken);
        var script = BuildSave(table.Name, changes, kinds);
        using var response = await QueryAsync(script, table.Schema ?? _settings.Database, cancellationToken, throwOnError: false);
        var errors = response.Results.Where(r => !r.Ok).Select(r => r.Error ?? string.Empty).ToArray();
        if (errors.Length == 0)
        {
            return changes.Count;
        }

        var marker = errors.FirstOrDefault(e => e.Contains(RowCountMarker, StringComparison.Ordinal));
        if (marker is not null)
        {
            throw new RowCountMismatchException(1, 0, marker);
        }

        throw new ServerRequestException(RootCause(errors));
    }

    internal static string BuildSave(string table, IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, SurrealKind> kinds)
    {
        var parameters = new SurrealParams();
        var body = new StringBuilder();
        for (var i = 0; i < changes.Count; i++)
        {
            switch (changes[i])
            {
                case RowUpdate update:
                {
                    if (update.Values.Keys.FirstOrDefault(k => k is "id" or "in" or "out") is { } reserved)
                    {
                        throw new InvalidOperationException(reserved == "id"
                            ? "A record's id cannot be edited."
                            : $"'{reserved}' cannot be saved from the grid. Delete the relation and RELATE it again.");
                    }

                    var record = parameters.Add(Record(update.Key, table));
                    var data = parameters.Add(ObjectLiteral(update.Values, kinds, table, skipNulls: false));
                    body.Append(Exists(record, i)).Append("UPDATE ").Append(record).Append(" MERGE ").Append(data).Append(";\n");
                    break;
                }

                case RowInsert insert:
                {
                    var target = insert.Values.TryGetValue("id", out var id) && Convert.ToString(id, CultureInfo.InvariantCulture) is { Length: > 0 } idText
                        && SurrealRecordId.Parse(idText, table) is { } record
                        ? parameters.Add(record.Expression(idText))
                        : SurrealQl.Ident(table);
                    var content = insert.Values.Where(v => v.Key != "id").ToDictionary();
                    var data = parameters.Add(ObjectLiteral(content, kinds, table, skipNulls: true));
                    body.Append("CREATE ").Append(target).Append(" CONTENT ").Append(data).Append(";\n");
                    break;
                }

                case RowDelete delete:
                {
                    var record = parameters.Add(Record(delete.Key, table));
                    body.Append(Exists(record, i)).Append("DELETE ").Append(record).Append(";\n");
                    break;
                }

                default:
                    throw new NotSupportedException(changes[i].GetType().Name);
            }
        }

        return "BEGIN TRANSACTION;\n" + parameters.Prefix + body + "COMMIT TRANSACTION;";
    }

    private static string Exists(string record, int index) =>
        string.Create(CultureInfo.InvariantCulture, $"IF array::len(SELECT id FROM {record}) != 1 {{ THROW \"{RowCountMarker}:{index}\" }};\n");

    private static string Record(IReadOnlyDictionary<string, object?> key, string table)
    {
        var text = key.TryGetValue("id", out var id) ? Convert.ToString(id, CultureInfo.InvariantCulture) : null;
        return text is not null && SurrealRecordId.Parse(text, table) is { } record
            ? record.Expression(text)
            : throw new InvalidOperationException("The record's id is unknown, so it cannot be addressed.");
    }

    /// <summary>An object literal whose values are the fields' typed expressions.</summary>
    internal static string ObjectLiteral(IReadOnlyDictionary<string, object?> values, IReadOnlyDictionary<string, SurrealKind> kinds, string table, bool skipNulls)
    {
        var sb = new StringBuilder("{ ");
        var first = true;
        foreach (var (column, value) in values)
        {
            if (skipNulls && value is null)
            {
                continue;
            }

            if (!first)
            {
                sb.Append(", ");
            }

            first = false;
            kinds.TryGetValue(column, out var kind);
            sb.Append(SurrealQl.String(column)).Append(": ").Append(SurrealQl.Value(value, kind, table));
        }

        return sb.Append(first ? "}" : " }").ToString();
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        var state = new SurrealChannelState(this);
        return Task.FromResult<IQueryChannel>(new HttpQueryChannel(state.RunAsync));
    }

    public ValueTask DisposeAsync()
    {
        _transport.Dispose();
        return ValueTask.CompletedTask;
    }

    internal async Task<IReadOnlyDictionary<string, SurrealKind>> KindsAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var database = table.Schema ?? _settings.Database;
        if (_kinds.TryGetValue((database, table.Name), out var cached))
        {
            return cached;
        }

        await GetStructureAsync(table, cancellationToken);
        return _kinds[(database, table.Name)];
    }

    internal void ForgetKinds() => _kinds.Clear();

    /// <summary>A response held open so its results can be read; disposing it frees the parsed JSON.</summary>
    internal sealed class SurrealResponse(JsonDocument document, IReadOnlyList<SurrealResult> results) : IDisposable
    {
        public IReadOnlyList<SurrealResult> Results { get; } = results;

        public void Dispose() => document.Dispose();
    }

    internal async Task<SurrealResponse> QueryAsync(string sql, string? database, CancellationToken cancellationToken, bool throwOnError = true, bool noNamespace = false, string? namespaceOverride = null)
    {
        var ns = noNamespace ? null : namespaceOverride ?? _settings.Namespace;
        var reply = await _transport.SendAsync(HttpMethod.Post, "/sql", new StringContent(sql, Encoding.UTF8, "text/plain"), cancellationToken, request =>
        {
            if (ns is not null)
            {
                request.Headers.TryAddWithoutValidation("Surreal-NS", ns);
                if (database is not null)
                {
                    request.Headers.TryAddWithoutValidation("Surreal-DB", database);
                }
            }
        });

        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(SurrealErrors.Reason(reply), reply.StatusCode);
        }

        var document = reply.TryParseJson() ?? throw new ServerRequestException("SurrealDB answered something other than JSON.");
        var results = new List<SurrealResult>();
        if (document.RootElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in document.RootElement.EnumerateArray())
            {
                var ok = !item.TryGetProperty("status", out var status) || status.GetString() == "OK";
                var value = item.TryGetProperty("result", out var result) ? result : default;
                results.Add(new SurrealResult(ok, value, ok ? null : value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString()));
            }
        }

        if (throwOnError && results.Any(r => !r.Ok))
        {
            var errors = results.Where(r => !r.Ok).Select(r => r.Error ?? string.Empty).ToArray();
            document.Dispose();
            throw new ServerRequestException(RootCause(errors));
        }

        if (results.Count == 0)
        {
            document.Dispose();
            throw new ServerRequestException("SurrealDB returned no result.");
        }

        return new SurrealResponse(document, results);
    }

    private async Task QueryValueAsync(string sql, string? database, CancellationToken cancellationToken)
    {
        using var _ = await QueryAsync(sql, database, cancellationToken);
    }

    /// <summary>
    /// In a failed transaction every statement reports that it was not executed; the one error that says why is the
    /// one worth showing.
    /// </summary>
    internal static string RootCause(IReadOnlyList<string> errors) =>
        errors.FirstOrDefault(e => !e.Contains("not executed due to a failed transaction", StringComparison.OrdinalIgnoreCase)
            && !e.Contains("cancelled transaction", StringComparison.OrdinalIgnoreCase))
        ?? (errors.Count > 0 ? errors[0] : "The query failed.");

    private static JsonElement SingleValue(IReadOnlyList<SurrealResult> results) => results[^1].Value;

    private static string[] Names(JsonElement info, string section) => [.. Entries(info, section).Select(e => e.Name).Order(StringComparer.Ordinal)];

    /// <summary>
    /// The entries of one section of an INFO result: a map of name to DEFINE statement on SurrealDB 1 and 2, a list of
    /// objects with a name in the structured form.
    /// </summary>
    internal static IEnumerable<(string Name, string Definition)> Entries(JsonElement info, string section)
    {
        if (info.ValueKind != JsonValueKind.Object || !info.TryGetProperty(section, out var entries))
        {
            yield break;
        }

        if (entries.ValueKind == JsonValueKind.Object)
        {
            foreach (var entry in entries.EnumerateObject().OrderBy(e => e.Name, StringComparer.Ordinal))
            {
                yield return (entry.Name, entry.Value.ValueKind == JsonValueKind.String ? entry.Value.GetString() ?? string.Empty : entry.Value.GetRawText());
            }
        }
        else if (entries.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in entries.EnumerateArray())
            {
                if (entry.TryGetProperty("name", out var name) && name.GetString() is { } text)
                {
                    var definition = entry.TryGetProperty("kind", out var kind) && kind.ValueKind == JsonValueKind.String
                        ? $"DEFINE FIELD {text} TYPE {kind.GetString()}"
                        : entry.GetRawText();
                    yield return (text, definition);
                }
            }
        }
    }

    /// <summary>The type of a <c>DEFINE FIELD</c>, the text after TYPE up to the next clause.</summary>
    internal static string KindOf(string definition)
    {
        var start = definition.IndexOf(" TYPE ", StringComparison.OrdinalIgnoreCase);
        if (start < 0)
        {
            return string.Empty;
        }

        var tail = definition[(start + 6)..];
        var end = tail.Length;
        foreach (var clause in new[] { " PERMISSIONS", " DEFAULT", " VALUE", " ASSERT", " READONLY", " COMMENT", " FLEXIBLE", " REFERENCE" })
        {
            var found = tail.IndexOf(clause, StringComparison.OrdinalIgnoreCase);
            if (found >= 0 && found < end)
            {
                end = found;
            }
        }

        return tail[..end].Trim();
    }

    private static string? Default(string definition)
    {
        var start = definition.IndexOf(" DEFAULT ", StringComparison.OrdinalIgnoreCase);
        if (start < 0)
        {
            return null;
        }

        var tail = definition[(start + 9)..];
        foreach (var clause in new[] { " PERMISSIONS", " VALUE", " ASSERT", " READONLY", " COMMENT" })
        {
            var found = tail.IndexOf(clause, StringComparison.OrdinalIgnoreCase);
            if (found >= 0)
            {
                tail = tail[..found];
            }
        }

        return tail.Trim();
    }

    private static string[] IndexColumns(string definition)
    {
        foreach (var keyword in new[] { " FIELDS ", " COLUMNS " })
        {
            var start = definition.IndexOf(keyword, StringComparison.OrdinalIgnoreCase);
            if (start < 0)
            {
                continue;
            }

            var tail = definition[(start + keyword.Length)..];
            foreach (var clause in new[] { " UNIQUE", " SEARCH", " MTREE", " HNSW", " COMMENT", " CONCURRENTLY", " FULLTEXT", " COUNT" })
            {
                var found = tail.IndexOf(clause, StringComparison.OrdinalIgnoreCase);
                if (found >= 0)
                {
                    tail = tail[..found];
                }
            }

            return tail.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        }

        return [];
    }

    private static string Infer(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Number => value.TryGetInt64(out _) ? "int" : "float",
        JsonValueKind.True or JsonValueKind.False => "bool",
        JsonValueKind.Object => "object",
        JsonValueKind.Array => "array",
        JsonValueKind.String => "string",
        _ => "any",
    };

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}

internal static class SurrealErrors
{
    /// <summary>A refused request answers <c>{"code", "details", "description", "information"}</c>; information says most.</summary>
    public static string Reason(HttpReply reply)
    {
        string? reason = null;
        using (var json = reply.TryParseJson())
        {
            if (json is not null && json.RootElement.ValueKind == JsonValueKind.Object)
            {
                foreach (var key in new[] { "information", "description", "details", "message", "error" })
                {
                    if (json.RootElement.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text)
                    {
                        reason = text;
                        break;
                    }
                }
            }
            else if (json is not null && json.RootElement.ValueKind == JsonValueKind.Array)
            {
                reason = SurrealDbSession.RootCause([.. json.RootElement.EnumerateArray()
                    .Where(r => r.TryGetProperty("status", out var s) && s.GetString() != "OK" && r.TryGetProperty("result", out _))
                    .Select(r => r.GetProperty("result").ToString())]);
            }
        }

        reason ??= reply.Body.Length > 0 ? reply.Text.Trim() : $"HTTP {reply.StatusCode}";
        return reply.StatusCode is 401 or 403 ? "Authentication failed: " + reason : reason;
    }
}
