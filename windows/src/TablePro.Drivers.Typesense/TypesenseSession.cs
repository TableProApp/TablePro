using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.CompilerServices;
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
using TablePro.Drivers.Typesense.Localization;

namespace TablePro.Drivers.Typesense;

/// <summary>Typesense over its REST API, signed with the API key from the password field.</summary>
public sealed class TypesenseDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Typesense];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var handler = HttpEndpoint.CreateHandler(request.Profile.SslMode, request.Profile.ConnectTimeoutSeconds);
        return await TypesenseSession.ConnectAsync(request, handler, cancellationToken);
    }
}

/// <summary>A connected Typesense node: collections are collections, aliases are views, API keys stand in for users.</summary>
internal sealed partial class TypesenseSession : IDatabaseSession, IUserListProvider
{
    public const string ApiKeyHeader = "X-TYPESENSE-API-KEY";

    /// <summary>"Only upto 250 hits can be fetched per page", for per_page and limit alike.</summary>
    internal const int MaxHitsPerSearch = 250;

    /// <summary><c>limit_multi_searches</c> defaults to 50; the 51st search fails the whole batch.</summary>
    internal const int MaxSearchesPerRequest = 50;

    private readonly HttpTransport _transport;
    private readonly ConcurrentDictionary<string, TsCollection> _collections = new(StringComparer.Ordinal);

    private TypesenseSession(ConnectionProfile profile, HttpTransport transport, string version)
    {
        Profile = profile;
        _transport = transport;
        ServerVersion = version;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => TypesenseDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    public static async Task<TypesenseSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler handler, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var profile = request.Profile;
        var transport = new HttpTransport(handler, HttpEndpoint.BaseUri(request.Host, request.Port, profile.SslMode != SslMode.Disabled));
        try
        {
            transport.DefaultHeaders.Accept.ParseAdd("application/json");
            if (!string.IsNullOrEmpty(request.Password))
            {
                transport.DefaultHeaders.TryAddWithoutValidation(ApiKeyHeader, request.Password);
            }

            var version = await transport.ProbeAsync(profile.SslMode, request.Host, profile.ConnectTimeoutSeconds, async token =>
            {
                // /debug carries the version but needs an admin key; a narrower key is checked against /collections.
                var debug = await transport.SendAsync(HttpMethod.Get, "/debug", (string?)null, token);
                if (debug.IsSuccess)
                {
                    using var json = debug.TryParseJson();
                    return json is not null && json.RootElement.TryGetProperty("version", out var v) ? v.GetString() ?? string.Empty : string.Empty;
                }

                var collections = await transport.SendAsync(HttpMethod.Get, "/collections", (string?)null, token);
                return collections.IsSuccess ? string.Empty : throw new ServerRequestException(TsErrors.Reason(collections), collections.StatusCode);
            }, cancellationToken);
            return new TypesenseSession(profile, transport, version);
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
        using var _ = await RequestAsync(HttpMethod.Get, "/health", null, cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var collectionsTask = RequestAsync(HttpMethod.Get, "/collections", null, cancellationToken);
        var aliasesTask = TryRequestAsync("/aliases", cancellationToken);
        using var collections = await collectionsTask;
        using var aliases = await aliasesTask;
        var objects = new List<DatabaseObject>();
        foreach (var json in collections.RootElement.EnumerateArray())
        {
            var collection = TsCollection.Parse(json);
            _collections[collection.Name] = collection;
            objects.Add(new DatabaseObject(new ObjectName(null, collection.Name), ObjectKind.Collection, collection.Documents));
        }

        objects.Sort((a, b) => string.Compare(a.Name.Name, b.Name.Name, StringComparison.OrdinalIgnoreCase));
        if (aliases is not null && aliases.RootElement.TryGetProperty("aliases", out var list))
        {
            foreach (var alias in list.EnumerateArray())
            {
                var name = alias.GetProperty("name").GetString() ?? string.Empty;
                var target = alias.TryGetProperty("collection_name", out var c) ? c.GetString() : null;
                objects.Add(new DatabaseObject(new ObjectName(null, name), ObjectKind.View, null, target is null ? CoreStrings.Get("Driver/Alias") : CoreStrings.Format("Driver/AliasOf", target)));
            }
        }

        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var collection = await CollectionAsync(table.Name, cancellationToken, refresh: true);
        var columns = new List<ColumnInfo> { new(TsCollection.IdColumn, "string", false, null, true, false, 0) };
        foreach (var field in collection.Columns)
        {
            var notes = string.Join(", ", new[] { field.IsFacet ? "facet" : null, field.IsSortable ? "sort" : null }.Where(n => n is not null));
            columns.Add(new ColumnInfo(field.Name, field.Type, field.IsOptional, null, false, false, columns.Count, notes.Length == 0 ? null : notes));
        }

        var indexes = new List<IndexInfo> { new(TsCollection.IdColumn, [TsCollection.IdColumn], true, true) };
        indexes.AddRange(collection.Columns.Where(f => f.IsFacet).Select(f => new IndexInfo(f.Name, [f.Name], false, false, "facet")));
        return new TableStructure(table, columns, indexes, [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var segment = TsDocuments.Segment(obj.Name.Name);
        if (obj.Kind == ObjectKind.View)
        {
            using var alias = await RequestAsync(HttpMethod.Get, $"/aliases/{segment}", null, cancellationToken);
            var target = alias.RootElement.TryGetProperty("collection_name", out var c) ? c.GetString() : null;
            return $"PUT /aliases/{segment}\n" + JsonCells.Pretty(JsonCells.ToJson(new JsonObject { ["collection_name"] = target }));
        }

        using var schema = await RequestAsync(HttpMethod.Get, $"/collections/{segment}", null, cancellationToken);
        var node = JsonNode.Parse(schema.RootElement.GetRawText())!.AsObject();

        // Counters and timestamps describe the collection's state; a create request does not take them.
        node.Remove("num_documents");
        node.Remove("created_at");
        return "POST /collections\n" + JsonCells.Pretty(JsonCells.ToJson(node));
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var collection = await CollectionAsync(request.Table.Name, cancellationToken);
        var filterBy = TsFilter.FilterBy(request.Filter, collection.ByName);
        var sortBy = TsFilter.SortBy(request.Sort, collection.ByName);
        var (q, queryBy) = TsFilter.Query(request.Filter, collection);
        var table = NewTable(collection);

        // A page above 250 rows is several searches; one multi_search carries up to 50 of them in one round trip, and
        // a body has no URL length limit for a long IN list.
        var chunks = new List<(int Offset, int Limit)>();
        for (var taken = 0; taken < request.Limit; taken += MaxHitsPerSearch)
        {
            chunks.Add((request.Offset + taken, Math.Min(MaxHitsPerSearch, request.Limit - taken)));
        }

        foreach (var batch in chunks.Chunk(MaxSearchesPerRequest))
        {
            var searches = new JsonArray();
            foreach (var (offset, limit) in batch)
            {
                searches.Add((JsonNode)Search(request.Table.Name, q, queryBy, filterBy, sortBy, offset, limit));
            }

            using var response = await RequestAsync(HttpMethod.Post, "/multi_search", JsonCells.ToJson(new JsonObject { ["searches"] = searches }), cancellationToken);
            var exhausted = false;
            var i = 0;
            foreach (var result in Results(response.RootElement))
            {
                var added = AddHits(table, result, collection);
                if (added < batch[i++].Limit)
                {
                    exhausted = true;
                    break;
                }
            }

            if (exhausted || i < batch.Length)
            {
                break;
            }
        }

        return table.Build();
    }

    internal static JsonObject Search(string collection, string q, string? queryBy, string? filterBy, string? sortBy, int offset, int limit)
    {
        var search = new JsonObject { ["collection"] = collection, ["q"] = q, ["offset"] = offset, ["limit"] = limit };
        if (queryBy is not null)
        {
            search["query_by"] = queryBy;
        }

        if (filterBy is not null)
        {
            search["filter_by"] = filterBy;
        }

        if (sortBy is not null)
        {
            search["sort_by"] = sortBy;
        }

        return search;
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var collection = await CollectionAsync(table.Name, cancellationToken);
        var (q, queryBy) = TsFilter.Query(filter, collection);
        var search = Search(table.Name, q, queryBy, TsFilter.FilterBy(filter, collection.ByName), null, 0, 0);
        search.Remove("offset");
        search.Remove("limit");
        search["per_page"] = 0;
        using var response = await RequestAsync(HttpMethod.Post, "/multi_search", JsonCells.ToJson(new JsonObject { ["searches"] = new JsonArray(search) }), cancellationToken);
        var result = Results(response.RootElement).FirstOrDefault();
        return result.ValueKind == JsonValueKind.Object && result.TryGetProperty("found", out var found) ? found.GetInt64() : 0;
    }

    /// <summary>
    /// Typesense has no transactions. One change is one request; several of a kind go as one import or one delete by
    /// filter. A document that is gone fails the save.
    /// </summary>
    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        if (changes.Count == 0)
        {
            return 0;
        }

        var collection = await CollectionAsync(table.Name, cancellationToken);
        var documents = $"/collections/{TsDocuments.Segment(table.Name)}/documents";
        var updates = changes.OfType<RowUpdate>().ToArray();
        var inserts = changes.OfType<RowInsert>().ToArray();
        var deletes = changes.OfType<RowDelete>().ToArray();
        var saved = 0;

        if (updates.Length == 1)
        {
            var id = Id(updates[0].Key);
            var body = TsDocuments.Build(updates[0].Values.Where(v => v.Key != TsCollection.IdColumn).ToDictionary(), collection.ByName, skipNulls: false);
            saved += await SingleAsync(HttpMethod.Patch, $"{documents}/{TsDocuments.Segment(id)}", JsonCells.ToJson(body), cancellationToken);
        }
        else if (updates.Length > 1)
        {
            saved += await ImportAsync(documents, "update", updates.Select(u =>
            {
                var document = TsDocuments.Build(u.Values.Where(v => v.Key != TsCollection.IdColumn).ToDictionary(), collection.ByName, skipNulls: false);
                document[TsCollection.IdColumn] = Id(u.Key);
                return document;
            }), saved, changes.Count, cancellationToken);
        }

        if (inserts.Length == 1)
        {
            saved += await SingleAsync(HttpMethod.Post, documents, JsonCells.ToJson(TsDocuments.Build(inserts[0].Values, collection.ByName, skipNulls: true)), cancellationToken);
        }
        else if (inserts.Length > 1)
        {
            saved += await ImportAsync(documents, "create", inserts.Select(i => TsDocuments.Build(i.Values, collection.ByName, skipNulls: true)), saved, changes.Count, cancellationToken);
        }

        if (deletes.Length == 1)
        {
            saved += await SingleAsync(HttpMethod.Delete, $"{documents}/{TsDocuments.Segment(Id(deletes[0].Key))}", null, cancellationToken);
        }
        else if (deletes.Length > 1)
        {
            var ids = string.Join(',', deletes.Select(d => TsFilter.Text(Id(d.Key), TsCollection.IdColumn)));
            using var response = await RequestAsync(HttpMethod.Delete, $"{documents}?filter_by={Uri.EscapeDataString($"id:[{ids}]")}", null, cancellationToken);
            var deleted = response.RootElement.TryGetProperty("num_deleted", out var n) ? n.GetInt32() : 0;
            saved += deleted;
            if (deleted != deletes.Length)
            {
                throw new RowCountMismatchException(deletes.Length, deleted, $"DELETE {documents}");
            }
        }

        return saved;
    }

    private async Task<int> SingleAsync(HttpMethod method, string path, string? body, CancellationToken cancellationToken)
    {
        var reply = await _transport.SendAsync(method, path, body, cancellationToken);
        if (reply.StatusCode == 404 && method != HttpMethod.Post)
        {
            throw new RowCountMismatchException(1, 0, $"{method} {path}");
        }

        return reply.IsSuccess ? 1 : throw new ServerRequestException(TsErrors.Reason(reply), reply.StatusCode);
    }

    /// <summary>An import answers one JSON line per document, each saying whether that document was written.</summary>
    private async Task<int> ImportAsync(string documents, string action, IEnumerable<JsonObject> lines, int savedBefore, int total, CancellationToken cancellationToken)
    {
        var reply = await _transport.SendAsync(HttpMethod.Post, $"{documents}/import?action={action}", TsDocuments.Jsonl(lines), cancellationToken, "text/plain");
        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(TsErrors.Reason(reply), reply.StatusCode);
        }

        var ok = 0;
        string? firstError = null;
        foreach (var line in reply.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            using var result = JsonDocument.Parse(line);
            if (result.RootElement.TryGetProperty("success", out var success) && success.ValueKind == JsonValueKind.True)
            {
                ok++;
            }
            else
            {
                firstError ??= result.RootElement.TryGetProperty("error", out var error) ? error.GetString() : line;
            }
        }

        return firstError is null
            ? ok
            : throw new ServerRequestException(CoreStrings.Format("Driver/PartialSaveNoTransaction", savedBefore + ok, total, "Typesense", firstError));
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) => Task.FromResult<IQueryChannel>(new HttpQueryChannel(RunStatementAsync));

    /// <summary>API keys are what Typesense has in place of users. The full key value is shown only when it is created.</summary>
    public async Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken)
    {
        await Yield();
        using var response = await RequestAsync(HttpMethod.Get, "/keys", null, cancellationToken);
        var table = new DocumentTable();
        table.Declare("id", "int64", typeof(long));
        table.Declare("description", "string", typeof(string));
        table.Declare("actions", "string[]", typeof(string));
        table.Declare("collections", "string[]", typeof(string));
        table.Declare("value_prefix", "string", typeof(string));
        table.Declare("expires_at", "datetime", typeof(DateTimeOffset));
        if (response.RootElement.TryGetProperty("keys", out var keys))
        {
            foreach (var key in keys.EnumerateArray())
            {
                table.NewRow();
                foreach (var name in new[] { "id", "description", "actions", "collections", "value_prefix" })
                {
                    if (key.TryGetProperty(name, out var value))
                    {
                        table.Set(name, value);
                    }
                }

                // Typesense writes a key that never expires as a far-future timestamp.
                if (key.TryGetProperty("expires_at", out var expires) && expires.TryGetInt64(out var seconds) && seconds < 253402300799)
                {
                    table.Set("expires_at", DateTimeOffset.FromUnixTimeSeconds(seconds));
                }
            }
        }

        return table.Build();
    }

    public ValueTask DisposeAsync()
    {
        _transport.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task<StatementOutcome> RunStatementAsync(string statement, ExecuteOptions options, CancellationToken cancellationToken)
    {
        if (!RequestBlock.TryParse(statement, out var block))
        {
            throw new ArgumentException(CoreStrings.Format("Driver/EnterRequestLike", "GET /collections"));
        }

        var import = block.Path.Contains("/import", StringComparison.OrdinalIgnoreCase);
        var reply = await _transport.SendAsync(block.HttpMethod, block.Path, block.Body, cancellationToken, import ? "text/plain" : "application/json");
        if (block.Method is not ("GET" or "HEAD"))
        {
            _collections.Clear();
        }

        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(TsErrors.Reason(reply), reply.StatusCode);
        }

        return TsResponses.Render(reply, options.RowLimit);
    }

    private async Task<TsCollection> CollectionAsync(string name, CancellationToken cancellationToken, bool refresh = false)
    {
        if (!refresh && _collections.TryGetValue(name, out var cached))
        {
            return cached;
        }

        using var response = await RequestAsync(HttpMethod.Get, $"/collections/{TsDocuments.Segment(name)}", null, cancellationToken);
        var collection = TsCollection.Parse(response.RootElement);
        _collections[name] = collection;
        return collection;
    }

    private static DocumentTable NewTable(TsCollection collection)
    {
        var table = new DocumentTable();
        table.Declare(TsCollection.IdColumn, "string", typeof(string));
        foreach (var field in collection.Columns)
        {
            table.Declare(field.Name, field.Type, field.ClrType);
        }

        return table;
    }

    private static int AddHits(DocumentTable table, JsonElement result, TsCollection collection)
    {
        if (result.TryGetProperty("error", out var error))
        {
            throw new ServerRequestException(error.GetString() ?? TypesenseStrings.Get("Typesense/SearchFailed"), result.TryGetProperty("code", out var code) ? code.GetInt32() : 0);
        }

        var added = 0;
        if (result.TryGetProperty("hits", out var hits))
        {
            foreach (var hit in hits.EnumerateArray())
            {
                if (hit.TryGetProperty("document", out var document))
                {
                    table.NewRow();
                    SetDocument(table, document, string.Empty, collection.ByName);
                    added++;
                }
            }
        }

        return added;
    }

    /// <summary>Flattens along the schema, keeping an object field without declared leaves whole as one cell.</summary>
    private static void SetDocument(DocumentTable table, JsonElement value, string path, IReadOnlyDictionary<string, TsField> fields)
    {
        if (value.ValueKind == JsonValueKind.Object && (path.Length == 0 || !(fields.TryGetValue(path, out var field) && field.IsObject && !fields.Keys.Any(k => k.StartsWith(path + ".", StringComparison.Ordinal)))))
        {
            foreach (var property in value.EnumerateObject())
            {
                SetDocument(table, property.Value, path.Length == 0 ? property.Name : $"{path}.{property.Name}", fields);
            }

            return;
        }

        table.Set(path, value);
    }

    internal static IEnumerable<JsonElement> Results(JsonElement response)
    {
        if (response.TryGetProperty("results", out var results))
        {
            foreach (var result in results.EnumerateArray())
            {
                yield return result;
            }
        }
    }

    private async Task<JsonDocument> RequestAsync(HttpMethod method, string path, string? body, CancellationToken cancellationToken)
    {
        var reply = await _transport.SendAsync(method, path, body, cancellationToken);
        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(TsErrors.Reason(reply), reply.StatusCode);
        }

        return reply.TryParseJson() ?? JsonDocument.Parse("{}");
    }

    private async Task<JsonDocument?> TryRequestAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            var reply = await _transport.SendAsync(HttpMethod.Get, path, (string?)null, cancellationToken);
            return reply.IsSuccess ? reply.TryParseJson() : null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
    }

    private static string Id(IReadOnlyDictionary<string, object?> key) =>
        key.TryGetValue(TsCollection.IdColumn, out var id) && Convert.ToString(id, CultureInfo.InvariantCulture) is { Length: > 0 } text
            ? text
            : throw new InvalidOperationException(CoreStrings.Format("Driver/DocumentIdUnknown", "id"));

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}

internal static class TsErrors
{
    /// <summary>Typesense answers <c>{"message": "..."}</c> on failure.</summary>
    public static string Reason(HttpReply reply)
    {
        string? reason = null;
        using (var json = reply.TryParseJson())
        {
            if (json is not null && json.RootElement.ValueKind == JsonValueKind.Object)
            {
                if (json.RootElement.TryGetProperty("message", out var message))
                {
                    reason = message.ToString();
                }
                else if (json.RootElement.TryGetProperty("error", out var error))
                {
                    reason = error.ToString();
                }
            }
        }

        reason ??= reply.Body.Length > 0 ? reply.Text.Trim() : $"HTTP {reply.StatusCode}";
        return reply.StatusCode is 401 or 403 ? CoreStrings.Format("Driver/AuthenticationFailedWith", reason) : reason;
    }
}

internal static class TsResponses
{
    public static StatementOutcome Render(HttpReply reply, int rowLimit)
    {
        using var json = reply.TryParseJson();
        if (json is null)
        {
            // An export answers JSON lines, which are documents one per line rather than one JSON value.
            return Lines(reply.Text, rowLimit) is { } lines ? StatementOutcome.Of(lines) : StatementOutcome.Of(JsonTables.Raw(reply.Text));
        }

        var root = json.RootElement;
        var search = SearchResult(root);
        if (search is { } result)
        {
            var table = new DocumentTable();
            table.Declare(TsCollection.IdColumn, "string", typeof(string));
            var truncated = false;
            foreach (var hit in result.GetProperty("hits").EnumerateArray())
            {
                if (table.RowCount >= rowLimit)
                {
                    truncated = true;
                    break;
                }

                if (hit.TryGetProperty("document", out var document))
                {
                    table.NewRow();
                    table.SetFlattened(document);
                }
            }

            return StatementOutcome.Of(table.Build(truncated));
        }

        var affected = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("num_deleted", out var deleted) && deleted.ValueKind == JsonValueKind.Number ? deleted.GetInt32() : -1;
        return StatementOutcome.Of(JsonTables.Auto(root, rowLimit), affected);
    }

    /// <summary>A search, or a multi_search of exactly one search; a batch of several has no single table to show.</summary>
    private static JsonElement? SearchResult(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (root.TryGetProperty("hits", out var hits) && hits.ValueKind == JsonValueKind.Array)
        {
            return root;
        }

        if (root.TryGetProperty("results", out var results) && results.ValueKind == JsonValueKind.Array && results.GetArrayLength() == 1
            && results[0].TryGetProperty("hits", out var inner) && inner.ValueKind == JsonValueKind.Array)
        {
            return results[0];
        }

        return null;
    }

    private static ResultSet? Lines(string text, int rowLimit)
    {
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length == 0)
        {
            return null;
        }

        var table = new DocumentTable();
        var truncated = false;
        foreach (var line in lines)
        {
            if (table.RowCount >= rowLimit)
            {
                truncated = true;
                break;
            }

            try
            {
                using var document = JsonDocument.Parse(line);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    return null;
                }

                table.NewRow();
                table.SetFlattened(document.RootElement);
            }
            catch (JsonException)
            {
                return null;
            }
        }

        return table.Build(truncated);
    }
}
