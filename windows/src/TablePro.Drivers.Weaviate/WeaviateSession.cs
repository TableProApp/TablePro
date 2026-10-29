using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Http;
using TablePro.Drivers.Weaviate.Localization;

namespace TablePro.Drivers.Weaviate;

/// <summary>Weaviate over REST for the catalog and writes, GraphQL for filtered reads and the editor.</summary>
public sealed class WeaviateDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Weaviate];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var handler = HttpEndpoint.CreateHandler(request.Profile.SslMode, request.Profile.ConnectTimeoutSeconds);
        return await WeaviateSession.ConnectAsync(request, handler, cancellationToken);
    }
}

/// <summary>A connected Weaviate instance: each class (collection) is a collection with its objects as rows.</summary>
internal sealed class WeaviateSession : IDatabaseSession, IServerVariablesProvider
{
    public const string TenantOption = "tenant";

    private readonly HttpTransport _transport;
    private readonly string? _tenant;
    private readonly ConcurrentDictionary<string, WvClass> _classes = new(StringComparer.Ordinal);

    private WeaviateSession(ConnectionProfile profile, HttpTransport transport, string version)
    {
        Profile = profile;
        _transport = transport;
        ServerVersion = version;
        _tenant = profile.AdditionalOptions.TryGetValue(TenantOption, out var tenant) && !string.IsNullOrWhiteSpace(tenant) ? tenant.Trim() : null;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => GraphQlDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    public static async Task<WeaviateSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler handler, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var profile = request.Profile;
        var transport = new HttpTransport(handler, HttpEndpoint.BaseUri(request.Host, request.Port, profile.SslMode != SslMode.Disabled));
        try
        {
            transport.DefaultHeaders.Accept.ParseAdd("application/json");
            if (!string.IsNullOrEmpty(request.Password))
            {
                transport.DefaultHeaders.Authorization = new AuthenticationHeaderValue("Bearer", request.Password);
            }

            // /v1/meta needs the key where the readiness probe does not, so a wrong key fails here and not on first use.
            var version = await transport.ProbeAsync(profile.SslMode, request.Host, profile.ConnectTimeoutSeconds, async token =>
            {
                using var meta = await RequestAsync(transport, HttpMethod.Get, "/v1/meta", null, token);
                return meta.RootElement.TryGetProperty("version", out var v) ? v.GetString() ?? string.Empty : string.Empty;
            }, cancellationToken);
            return new WeaviateSession(profile, transport, version);
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
        using var _ = await RequestAsync(_transport, HttpMethod.Get, "/v1/meta", null, cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var classes = await LoadSchemaAsync(cancellationToken);
        var counts = await CountAllAsync(classes, cancellationToken);
        return [.. classes.OrderBy(c => c.Name, StringComparer.OrdinalIgnoreCase).Select(c => WvObjects.ToObject(c, counts.TryGetValue(c.Name, out var n) ? n : null))];
    }

    /// <summary>
    /// Every class's object count in one Aggregate query. A multi-tenant class without a tenant fails the whole query,
    /// so the counts are a courtesy and their failure is not the sidebar's.
    /// </summary>
    private async Task<Dictionary<string, long>> CountAllAsync(IReadOnlyList<WvClass> classes, CancellationToken cancellationToken)
    {
        var counts = new Dictionary<string, long>(StringComparer.Ordinal);
        var countable = classes.Where(c => WvClass.IsName(c.Name) && (!c.MultiTenant || _tenant is not null)).ToArray();
        if (countable.Length == 0)
        {
            return counts;
        }

        var tenant = _tenant is null ? string.Empty : $"(tenant: {WvGraphQl.Quote(_tenant)})";
        var query = $"{{ Aggregate {{ {string.Join(' ', countable.Select(c => $"{c.Name}{(c.MultiTenant ? tenant : string.Empty)} {{ meta {{ count }} }}"))} }} }}";
        try
        {
            using var response = await GraphQlAsync(query, cancellationToken);
            if (response.RootElement.TryGetProperty("data", out var data) && data.TryGetProperty("Aggregate", out var aggregate))
            {
                foreach (var cls in aggregate.EnumerateObject())
                {
                    if (MetaCount(cls.Value) is { } count)
                    {
                        counts[cls.Name] = count;
                    }
                }
            }
        }
        catch (ServerRequestException)
        {
            // Counts stay unknown.
        }

        return counts;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var cls = await ClassAsync(table.Name, cancellationToken, refresh: true);
        var columns = new List<ColumnInfo> { new(WvClass.IdColumn, "uuid", false, null, true, false, 0) };
        foreach (var property in cls.Properties)
        {
            columns.Add(new ColumnInfo(property.Name, string.Join(" | ", property.DataTypes.DefaultIfEmpty("text")), true, null, false, false, columns.Count));
        }

        return new TableStructure(table, columns, [new IndexInfo(WvClass.IdColumn, [WvClass.IdColumn], true, true)], [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        using var response = await RequestAsync(_transport, HttpMethod.Get, $"/v1/schema/{Uri.EscapeDataString(obj.Name.Name)}", null, cancellationToken);
        return "POST /v1/schema\n" + JsonCells.Pretty(response.RootElement);
    }

    /// <summary>
    /// A plain page reads <c>/v1/objects</c>, which is cheapest; a filter or sort needs GraphQL Get, the only read that
    /// takes a where and a sort together.
    /// </summary>
    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var cls = await ClassAsync(request.Table.Name, cancellationToken);
        var table = WvObjects.NewTable(cls);
        if (request.Filter.IsEmpty && request.Sort.Count == 0)
        {
            var path = string.Create(CultureInfo.InvariantCulture, $"/v1/objects?class={Uri.EscapeDataString(cls.Name)}&limit={request.Limit}&offset={request.Offset}") + TenantQuery();
            using var response = await RequestAsync(_transport, HttpMethod.Get, path, null, cancellationToken);
            if (response.RootElement.TryGetProperty("objects", out var objects) && objects.ValueKind == JsonValueKind.Array)
            {
                foreach (var obj in objects.EnumerateArray())
                {
                    WvObjects.AddRest(table, obj);
                }
            }

            return table.Build();
        }

        using (var response = await GraphQlAsync(WvGraphQl.Get(cls, request, cls.MultiTenant ? _tenant : null), cancellationToken))
        {
            foreach (var (_, row) in WvObjects.GetRows(response.RootElement))
            {
                WvObjects.AddGraphQl(table, row);
            }
        }

        return table.Build();
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var cls = await ClassAsync(table.Name, cancellationToken);
        using var response = await GraphQlAsync(WvGraphQl.Count(cls, filter, cls.MultiTenant ? _tenant : null), cancellationToken);
        return response.RootElement.TryGetProperty("data", out var data) && data.TryGetProperty("Aggregate", out var aggregate)
            && aggregate.TryGetProperty(cls.Name, out var result) && MetaCount(result) is { } count
            ? count
            : 0;
    }

    /// <summary>Weaviate has no transactions, so each change is its own request and a failure reports what was saved.</summary>
    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        var cls = await ClassAsync(table.Name, cancellationToken);
        var className = Uri.EscapeDataString(cls.Name);
        var tenant = cls.MultiTenant ? _tenant : null;
        var saved = 0;
        foreach (var change in changes)
        {
            var (method, path, body) = change switch
            {
                RowUpdate update => (HttpMethod.Patch, $"/v1/objects/{className}/{Uri.EscapeDataString(Id(update.Key))}", Body(cls, update.Values, Id(update.Key), tenant, skipNulls: false)),
                RowInsert insert => (HttpMethod.Post, "/v1/objects", Body(cls, insert.Values, InsertId(insert), tenant, skipNulls: true)),
                RowDelete delete => (HttpMethod.Delete, $"/v1/objects/{className}/{Uri.EscapeDataString(Id(delete.Key))}", (string?)null),
                _ => throw new NotSupportedException(change.GetType().Name),
            };
            if (change is not RowInsert && tenant is not null)
            {
                path += "?tenant=" + Uri.EscapeDataString(tenant);
            }

            var reply = await _transport.SendAsync(method, path, body, cancellationToken);
            if (reply.StatusCode == 404 && change is not RowInsert)
            {
                throw new RowCountMismatchException(1, 0, $"{method} {path}");
            }

            if (!reply.IsSuccess)
            {
                var reason = WvErrors.Reason(reply);
                throw new ServerRequestException(saved == 0 ? reason : CoreStrings.Format("Driver/PartialSaveNoTransaction", saved, changes.Count, "Weaviate", reason), reply.StatusCode);
            }

            saved++;
        }

        return saved;
    }

    private static string Body(WvClass cls, IReadOnlyDictionary<string, object?> values, string? id, string? tenant, bool skipNulls)
    {
        var body = new JsonObject { ["class"] = cls.Name, ["properties"] = WvValues.Properties(values, cls, skipNulls) };
        if (id is not null)
        {
            body["id"] = id;
        }

        if (tenant is not null)
        {
            body["tenant"] = tenant;
        }

        return JsonCells.ToJson(body);
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) => Task.FromResult<IQueryChannel>(new HttpQueryChannel(RunStatementAsync));

    public async Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken)
    {
        await Yield();
        using var meta = await RequestAsync(_transport, HttpMethod.Get, "/v1/meta", null, cancellationToken);
        return JsonTables.PathValue(meta.RootElement, int.MaxValue);
    }

    public ValueTask DisposeAsync()
    {
        _transport.Dispose();
        return ValueTask.CompletedTask;
    }

    /// <summary>
    /// A statement is a GraphQL operation, or a REST request written as <c>GET /v1/schema</c>. Every REST path lives
    /// under <c>/v1</c>, so a path without it is prefixed.
    /// </summary>
    private async Task<StatementOutcome> RunStatementAsync(string statement, ExecuteOptions options, CancellationToken cancellationToken)
    {
        if (RequestBlock.TryParse(statement, out var block))
        {
            var path = block.Path is "/" or "/v1" || block.Path.StartsWith("/v1/", StringComparison.Ordinal) || block.Path.StartsWith("/v1?", StringComparison.Ordinal)
                ? block.Path
                : "/v1" + block.Path;
            if (block.Method == "POST" && path.StartsWith("/v1/graphql", StringComparison.Ordinal) && block.Body is not null)
            {
                return await RunGraphQlAsync(block.Body, options, cancellationToken);
            }

            var reply = await _transport.SendAsync(block.HttpMethod, path, block.Body, cancellationToken);
            if (block.Method is not ("GET" or "HEAD"))
            {
                _classes.Clear();
            }

            if (!reply.IsSuccess)
            {
                throw new ServerRequestException(WvErrors.Reason(reply), reply.StatusCode);
            }

            using var json = reply.TryParseJson();
            if (json is null)
            {
                return reply.Body.Length == 0 ? StatementOutcome.Empty : StatementOutcome.Of(JsonTables.Raw(reply.Text));
            }

            if (json.RootElement.ValueKind == JsonValueKind.Object && json.RootElement.TryGetProperty("objects", out var objects) && objects.ValueKind == JsonValueKind.Array)
            {
                var table = WvObjects.NewTable(null);
                var truncated = false;
                foreach (var obj in objects.EnumerateArray())
                {
                    if (table.RowCount >= options.RowLimit)
                    {
                        truncated = true;
                        break;
                    }

                    WvObjects.AddRest(table, obj);
                }

                return StatementOutcome.Of(table.Build(truncated));
            }

            return StatementOutcome.Of(JsonTables.Auto(json.RootElement, options.RowLimit));
        }

        return await RunGraphQlAsync(statement, options, cancellationToken);
    }

    private async Task<StatementOutcome> RunGraphQlAsync(string text, ExecuteOptions options, CancellationToken cancellationToken)
    {
        using var response = await GraphQlAsync(text, cancellationToken);
        var root = response.RootElement;
        if (WvObjects.GetRows(root).Any())
        {
            var table = WvObjects.NewTable(null);
            var truncated = false;
            foreach (var (_, row) in WvObjects.GetRows(root))
            {
                if (table.RowCount >= options.RowLimit)
                {
                    truncated = true;
                    break;
                }

                WvObjects.AddGraphQl(table, row);
            }

            return StatementOutcome.Of(table.Build(truncated));
        }

        var data = root.TryGetProperty("data", out var d) ? d : root;
        return StatementOutcome.Of(JsonTables.Auto(data, options.RowLimit));
    }

    /// <summary>Posts a GraphQL operation. Weaviate answers 200 with an <c>errors</c> list, which becomes the failure.</summary>
    private async Task<JsonDocument> GraphQlAsync(string query, CancellationToken cancellationToken)
    {
        var trimmed = query.Trim();
        var body = trimmed.StartsWith('{') && IsRequestObject(trimmed) ? trimmed : JsonCells.ToJson(new JsonObject { ["query"] = trimmed });
        var response = await RequestAsync(_transport, HttpMethod.Post, "/v1/graphql", body, cancellationToken);
        if (response.RootElement.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array && errors.GetArrayLength() > 0)
        {
            var messages = string.Join("\n", errors.EnumerateArray().Select(e => e.TryGetProperty("message", out var m) ? m.GetString() : e.GetRawText()));
            response.Dispose();
            throw new ServerRequestException(messages);
        }

        return response;
    }

    /// <summary>A pasted request body <c>{"query": "..."}</c> is sent as it is rather than wrapped again.</summary>
    private static bool IsRequestObject(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            return document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("query", out _);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private async Task<IReadOnlyList<WvClass>> LoadSchemaAsync(CancellationToken cancellationToken)
    {
        using var schema = await RequestAsync(_transport, HttpMethod.Get, "/v1/schema", null, cancellationToken);
        var classes = schema.RootElement.TryGetProperty("classes", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(WvClass.Parse).ToArray()
            : [];
        foreach (var cls in classes)
        {
            _classes[cls.Name] = cls;
        }

        return classes;
    }

    private async Task<WvClass> ClassAsync(string name, CancellationToken cancellationToken, bool refresh = false)
    {
        if (!refresh && _classes.TryGetValue(name, out var cached))
        {
            return cached;
        }

        using var response = await RequestAsync(_transport, HttpMethod.Get, $"/v1/schema/{Uri.EscapeDataString(name)}", null, cancellationToken);
        var cls = WvClass.Parse(response.RootElement);
        _classes[name] = cls;
        return cls;
    }

    private string TenantQuery() => _tenant is null ? string.Empty : "&tenant=" + Uri.EscapeDataString(_tenant);

    private static long? MetaCount(JsonElement result)
    {
        var first = result.ValueKind == JsonValueKind.Array && result.GetArrayLength() > 0 ? result[0] : result;
        return first.ValueKind == JsonValueKind.Object && first.TryGetProperty("meta", out var meta) && meta.TryGetProperty("count", out var count) && count.TryGetInt64(out var n)
            ? n
            : null;
    }

    private static async Task<JsonDocument> RequestAsync(HttpTransport transport, HttpMethod method, string path, string? body, CancellationToken cancellationToken)
    {
        var reply = await transport.SendAsync(method, path, body, cancellationToken);
        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(WvErrors.Reason(reply), reply.StatusCode);
        }

        return reply.TryParseJson() ?? JsonDocument.Parse("{}");
    }

    private static string? InsertId(RowInsert insert) =>
        insert.Values.TryGetValue(WvClass.IdColumn, out var id) && Convert.ToString(id, CultureInfo.InvariantCulture) is { Length: > 0 } text ? text : null;

    private static string Id(IReadOnlyDictionary<string, object?> key) =>
        key.TryGetValue(WvClass.IdColumn, out var id) && Convert.ToString(id, CultureInfo.InvariantCulture) is { Length: > 0 } text
            ? text
            : throw new InvalidOperationException(WeaviateStrings.Get("Weaviate/ObjectIdUnknown"));

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}

internal static class WvErrors
{
    /// <summary>Weaviate answers <c>{"error": [{"message": "..."}]}</c>, or a bare message from a proxy.</summary>
    public static string Reason(HttpReply reply)
    {
        string? reason = null;
        using (var json = reply.TryParseJson())
        {
            if (json is not null && json.RootElement.ValueKind == JsonValueKind.Object)
            {
                var root = json.RootElement;
                if (root.TryGetProperty("error", out var error))
                {
                    reason = error.ValueKind == JsonValueKind.Array
                        ? string.Join("\n", error.EnumerateArray().Select(e => e.TryGetProperty("message", out var m) ? m.GetString() : e.ToString()))
                        : error.ToString();
                }
                else if (root.TryGetProperty("message", out var message))
                {
                    reason = message.ToString();
                }
            }
        }

        if (string.IsNullOrWhiteSpace(reason))
        {
            reason = reply.Body.Length > 0 ? Encoding.UTF8.GetString(reply.Body).Trim() : $"HTTP {reply.StatusCode}";
        }

        return reply.StatusCode is 401 or 403 ? CoreStrings.Format("Driver/AuthenticationFailedWith", reason) : reason;
    }
}
