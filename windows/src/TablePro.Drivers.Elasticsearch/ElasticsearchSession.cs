using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.Elasticsearch;

/// <summary>
/// A connected cluster. Indices and data streams are collections, aliases are views; there are no databases or
/// schemas. Every call is a stateless REST request, so the editor's channel shares the session's client.
/// </summary>
internal sealed class ElasticsearchSession : IDatabaseSession, IServerActivityProvider, IServerVariablesProvider
{
    /// <summary>Elasticsearch's default <c>index.max_result_window</c>; from + size past it is refused.</summary>
    internal const int MaxResultWindow = 10_000;

    internal const int DeepPageBatch = 1_000;

    private const string PitKeepAlive = "1m";

    private readonly HttpTransport _transport;
    private readonly bool _caseInsensitive;
    private readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, EsField>> _mappings = new(StringComparer.Ordinal);
    private volatile HashSet<string> _dataStreams = new(StringComparer.Ordinal);

    private ElasticsearchSession(ConnectionProfile profile, HttpTransport transport, string version)
    {
        Profile = profile;
        _transport = transport;
        ServerVersion = version;
        _caseInsensitive = SupportsCaseInsensitive(version);
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => ElasticsearchDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    public string ProcessIdColumn => "task_id";

    internal Uri BaseAddress => _transport.BaseAddress;

    public static async Task<ElasticsearchSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler handler, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var transport = new HttpTransport(handler, ElasticsearchSettings.BaseUri(request));
        try
        {
            transport.DefaultHeaders.Authorization = ElasticsearchSettings.Authorization(request);
            transport.DefaultHeaders.Accept.ParseAdd("application/json");
            var version = await transport.ProbeAsync(request.Profile.SslMode, request.Host, request.Profile.ConnectTimeoutSeconds, async token =>
            {
                using var root = await RequestAsync(transport, HttpMethod.Get, "/", null, token);
                return root.RootElement.TryGetProperty("version", out var v) && v.TryGetProperty("number", out var number) ? number.GetString() ?? string.Empty : string.Empty;
            }, cancellationToken);
            return new ElasticsearchSession(request.Profile, transport, version);
        }
        catch
        {
            transport.Dispose();
            throw;
        }
    }

    /// <summary>The <c>case_insensitive</c> option on term, prefix and wildcard queries arrived in 7.10.</summary>
    internal static bool SupportsCaseInsensitive(string version)
    {
        var parts = version.Split('.');
        if (parts.Length == 0 || !int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var major))
        {
            return true;
        }

        var minor = parts.Length > 1 && int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var m) ? m : 0;
        return major > 7 || (major == 7 && minor >= 10);
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        using var _ = await RequestAsync(HttpMethod.Get, "/", null, cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var showHidden = ElasticsearchSettings.ShowHidden(Profile);
        var indicesTask = RequestAsync(HttpMethod.Get, "/_cat/indices?format=json&h=index,docs.count,store.size,health,status&s=index" + (showHidden ? "&expand_wildcards=all" : string.Empty), null, cancellationToken);

        // Data streams arrived in 7.9 and aliases need the monitor privilege, so either may fail without the indices failing.
        var streamsTask = TryRequestAsync(HttpMethod.Get, "/_data_stream", cancellationToken);
        var aliasesTask = TryRequestAsync(HttpMethod.Get, "/_cat/aliases?format=json&h=alias,index&s=alias", cancellationToken);

        using var indices = await indicesTask;
        using var streams = await streamsTask;
        using var aliases = await aliasesTask;

        var objects = new List<DatabaseObject>();
        var docCounts = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var row in indices.RootElement.EnumerateArray())
        {
            var name = Text(row, "index");
            if (name is null)
            {
                continue;
            }

            long? docs = long.TryParse(Text(row, "docs.count"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) ? count : null;
            if (docs is { } known)
            {
                docCounts[name] = known;
            }

            if (!showHidden && name.StartsWith('.'))
            {
                continue;
            }

            var comment = string.Join(" · ", new[] { Text(row, "health"), Text(row, "store.size") }.Where(s => !string.IsNullOrEmpty(s)));
            objects.Add(new DatabaseObject(new ObjectName(null, name), ObjectKind.Collection, docs, comment.Length == 0 ? null : comment));
        }

        var dataStreams = new HashSet<string>(StringComparer.Ordinal);
        if (streams is not null && streams.RootElement.TryGetProperty("data_streams", out var list))
        {
            foreach (var stream in list.EnumerateArray())
            {
                if (Text(stream, "name") is not { } name || (!showHidden && name.StartsWith('.')))
                {
                    continue;
                }

                dataStreams.Add(name);
                long? docs = null;
                if (stream.TryGetProperty("indices", out var backing))
                {
                    foreach (var index in backing.EnumerateArray())
                    {
                        if (Text(index, "index_name") is { } indexName && docCounts.TryGetValue(indexName, out var count))
                        {
                            docs = (docs ?? 0) + count;
                        }
                    }
                }

                objects.Add(new DatabaseObject(new ObjectName(null, name), ObjectKind.Collection, docs, "data stream"));
            }
        }

        _dataStreams = dataStreams;

        if (aliases is not null && aliases.RootElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var group in aliases.RootElement.EnumerateArray()
                .Select(row => (Alias: Text(row, "alias"), Index: Text(row, "index")))
                .Where(row => row.Alias is not null && (showHidden || !row.Alias.StartsWith('.')))
                .GroupBy(row => row.Alias!, StringComparer.Ordinal))
            {
                objects.Add(new DatabaseObject(new ObjectName(null, group.Key), ObjectKind.View, null, "alias of " + string.Join(", ", group.Select(g => g.Index))));
            }
        }

        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var fields = await MappingAsync(table.Name, cancellationToken);
        var columns = new List<ColumnInfo>(fields.Count + 2)
        {
            new(EsMapping.IdColumn, "keyword", false, null, true, false, 0, "document id"),
            new(EsMapping.IndexColumn, "keyword", false, null, false, false, 1, "the index holding the document"),
        };

        foreach (var field in fields.Values.OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase))
        {
            columns.Add(new ColumnInfo(field.Name, field.Type, true, null, false, false, columns.Count, field.HasKeyword ? "with keyword sub-field" : null));
        }

        return new TableStructure(table, columns, [new IndexInfo(EsMapping.IdColumn, [EsMapping.IdColumn], true, true)], [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var name = obj.Name.Name;
        var segment = EsWrites.Segment(name);
        if (obj.Kind == ObjectKind.View)
        {
            using var alias = await RequestAsync(HttpMethod.Get, $"/_alias/{segment}", null, cancellationToken);
            var actions = new JsonArray();
            foreach (var index in alias.RootElement.EnumerateObject())
            {
                var add = new JsonObject { ["index"] = index.Name, ["alias"] = name };
                if (index.Value.TryGetProperty("aliases", out var map) && map.TryGetProperty(name, out var options) && options.ValueKind == JsonValueKind.Object)
                {
                    foreach (var option in options.EnumerateObject())
                    {
                        add[option.Name] = JsonNode.Parse(option.Value.GetRawText());
                    }
                }

                actions.Add((JsonNode)new JsonObject { ["add"] = add });
            }

            return "POST /_aliases\n" + JsonCells.Pretty(JsonCells.ToJson(new JsonObject { ["actions"] = actions }));
        }

        if (_dataStreams.Contains(name))
        {
            using var stream = await RequestAsync(HttpMethod.Get, $"/_data_stream/{segment}", null, cancellationToken);
            var template = stream.RootElement.TryGetProperty("data_streams", out var list) && list.GetArrayLength() > 0 ? Text(list[0], "template") : null;
            var definition = $"PUT /_data_stream/{segment}";
            if (template is not null)
            {
                using var templates = await TryRequestAsync(HttpMethod.Get, $"/_index_template/{EsWrites.Segment(template)}", cancellationToken);
                if (templates is not null && templates.RootElement.TryGetProperty("index_templates", out var found) && found.GetArrayLength() > 0
                    && found[0].TryGetProperty("index_template", out var body))
                {
                    definition = $"PUT /_index_template/{EsWrites.Segment(template)}\n{JsonCells.Pretty(body)}\n\n{definition}";
                }
            }

            return definition;
        }

        using var response = await RequestAsync(HttpMethod.Get, $"/{segment}", null, cancellationToken);
        var root = response.RootElement.TryGetProperty(name, out var exact) ? exact : response.RootElement.EnumerateObject().First().Value;
        return $"PUT /{segment}\n" + JsonCells.Pretty(JsonCells.ToJson(CreateBody(root)));
    }

    /// <summary>
    /// The body that recreates an index. Settings the server sets itself (uuid, version, creation date, name) are left
    /// out, since a create request carrying them is refused.
    /// </summary>
    internal static JsonObject CreateBody(JsonElement index)
    {
        var body = new JsonObject();
        if (index.TryGetProperty("settings", out var settings))
        {
            var node = JsonNode.Parse(settings.GetRawText())!.AsObject();
            if (node["index"] is JsonObject indexSettings)
            {
                foreach (var key in new[] { "uuid", "version", "creation_date", "creation_date_string", "provided_name", "resize", "history_uuid" })
                {
                    indexSettings.Remove(key);
                }
            }

            body["settings"] = node;
        }

        if (index.TryGetProperty("mappings", out var mappings))
        {
            body["mappings"] = JsonNode.Parse(mappings.GetRawText());
        }

        if (index.TryGetProperty("aliases", out var aliases) && aliases.ValueKind == JsonValueKind.Object && aliases.EnumerateObject().Any())
        {
            body["aliases"] = JsonNode.Parse(aliases.GetRawText());
        }

        return body;
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var index = request.Table.Name;
        var fields = await MappingAsync(index, cancellationToken);
        var query = EsQuery.Build(request.Filter, fields, _caseInsensitive);
        var table = NewHitTable(fields);
        if (request.Offset + request.Limit <= MaxResultWindow)
        {
            var body = new JsonObject
            {
                ["from"] = request.Offset,
                ["size"] = request.Limit,
                ["track_total_hits"] = false,
                ["query"] = query,
            };
            var sort = EsQuery.Sort(request.Sort, fields);
            if (sort.Count > 0)
            {
                body["sort"] = sort;
            }

            using var response = await RequestAsync(HttpMethod.Post, $"/{EsWrites.Segment(index)}/_search", JsonCells.ToJson(body), cancellationToken);
            AddHits(table, response.RootElement, fields, int.MaxValue);
            return table.Build();
        }

        await DeepPageAsync(index, query, request, fields, table, cancellationToken);
        return table.Build();
    }

    /// <summary>
    /// Past the result window a page is reached by walking a point in time with <c>search_after</c>. The index is pinned
    /// so a write during the walk cannot shift documents between batches, and the skipped part carries no source.
    /// </summary>
    private async Task DeepPageAsync(string index, JsonObject query, BrowseRequest request, IReadOnlyDictionary<string, EsField> fields, DocumentTable table, CancellationToken cancellationToken)
    {
        string pit;
        using (var opened = await RequestAsync(HttpMethod.Post, $"/{EsWrites.Segment(index)}/_pit?keep_alive={PitKeepAlive}", null, cancellationToken))
        {
            pit = Text(opened.RootElement, "id") ?? throw new ServerRequestException("The cluster did not open a point in time.");
        }

        try
        {
            var skipped = 0;
            JsonNode? after = null;
            while (table.RowCount < request.Limit)
            {
                var skipping = skipped < request.Offset;
                var size = skipping ? Math.Min(MaxResultWindow, request.Offset - skipped) : Math.Min(DeepPageBatch, request.Limit - table.RowCount);
                var sort = EsQuery.Sort(request.Sort, fields);
                sort.Add((JsonNode)new JsonObject { ["_shard_doc"] = "asc" });
                var body = new JsonObject
                {
                    ["size"] = size,
                    ["track_total_hits"] = false,
                    ["query"] = query.DeepClone(),
                    ["sort"] = sort,
                    ["pit"] = new JsonObject { ["id"] = pit, ["keep_alive"] = PitKeepAlive },
                };
                if (skipping)
                {
                    body["_source"] = false;
                }

                if (after is not null)
                {
                    body["search_after"] = after.DeepClone();
                }

                using var response = await RequestAsync(HttpMethod.Post, "/_search", JsonCells.ToJson(body), cancellationToken);
                var hits = Hits(response.RootElement);
                var count = hits.ValueKind == JsonValueKind.Array ? hits.GetArrayLength() : 0;
                if (count == 0)
                {
                    break;
                }

                var last = hits[count - 1];
                after = last.TryGetProperty("sort", out var sortValues) ? JsonNode.Parse(sortValues.GetRawText()) : null;
                if (skipping)
                {
                    skipped += count;
                }
                else
                {
                    AddHits(table, response.RootElement, fields, request.Limit);
                }

                if (count < size || after is null)
                {
                    break;
                }

                if (response.RootElement.TryGetProperty("pit_id", out var nextPit) && nextPit.GetString() is { } refreshed)
                {
                    pit = refreshed;
                }
            }
        }
        finally
        {
            // Closing frees the search context early; it expires on its own if this fails.
            using var closed = await TryRequestAsync(HttpMethod.Delete, "/_pit", CancellationToken.None, JsonCells.ToJson(new JsonObject { ["id"] = pit }));
        }
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var fields = await MappingAsync(table.Name, cancellationToken);
        var body = new JsonObject { ["query"] = EsQuery.Build(filter, fields, _caseInsensitive) };
        using var response = await RequestAsync(HttpMethod.Post, $"/{EsWrites.Segment(table.Name)}/_count", JsonCells.ToJson(body), cancellationToken);
        return response.RootElement.TryGetProperty("count", out var count) ? count.GetInt64() : 0;
    }

    /// <summary>
    /// Elasticsearch has no transactions: one change is one request, several are one <c>_bulk</c>. A document that is
    /// gone fails the save; a bulk failure reports how many of the changes were applied before it.
    /// </summary>
    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        if (changes.Count == 0)
        {
            return 0;
        }

        var fields = await MappingAsync(table.Name, cancellationToken);
        if (changes.Count == 1)
        {
            var write = EsWrites.Single(table.Name, changes[0], fields);
            var reply = await _transport.SendAsync(new HttpMethod(write.Method), write.Path, write.Body, cancellationToken);
            if (reply.StatusCode == 404 && changes[0] is RowUpdate or RowDelete)
            {
                throw new RowCountMismatchException(1, 0, $"{write.Method} {write.Path}");
            }

            if (!reply.IsSuccess)
            {
                throw new ServerRequestException(EsErrors.Reason(reply), reply.StatusCode);
            }

            return 1;
        }

        var bulk = await _transport.SendAsync(HttpMethod.Post, "/_bulk?" + EsWrites.Refresh, EsWrites.Bulk(table.Name, changes, fields), cancellationToken, "application/x-ndjson");
        if (!bulk.IsSuccess)
        {
            throw new ServerRequestException(EsErrors.Reason(bulk), bulk.StatusCode);
        }

        using var result = bulk.TryParseJson() ?? throw new ServerRequestException("The bulk response was not JSON.");
        var saved = 0;
        string? firstError = null;
        var missing = 0;
        foreach (var item in result.RootElement.GetProperty("items").EnumerateArray())
        {
            var outcome = item.EnumerateObject().First().Value;
            var status = outcome.TryGetProperty("status", out var s) ? s.GetInt32() : 0;
            if (status is >= 200 and < 300)
            {
                saved++;
                continue;
            }

            if (status == 404)
            {
                missing++;
            }

            firstError ??= outcome.TryGetProperty("error", out var error) ? EsErrors.Describe(error) : $"HTTP {status}";
        }

        if (saved == changes.Count)
        {
            return saved;
        }

        if (missing == changes.Count - saved)
        {
            throw new RowCountMismatchException(changes.Count, saved, "POST /_bulk");
        }

        throw new ServerRequestException($"{saved} of {changes.Count} changes were saved; Elasticsearch has no transaction to undo them. {firstError}");
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) => Task.FromResult<IQueryChannel>(new HttpQueryChannel(RunStatementAsync));

    public async Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken)
    {
        await Yield();
        using var response = await RequestAsync(HttpMethod.Get, "/_tasks?detailed=true&group_by=none", null, cancellationToken);
        var table = new DocumentTable();
        table.Declare("task_id", "keyword", typeof(string));
        table.Declare("node", "keyword", typeof(string));
        table.Declare("action", "keyword", typeof(string));
        table.Declare("type", "keyword", typeof(string));
        table.Declare("description", "text", typeof(string));
        table.Declare("start_time", "date", typeof(DateTimeOffset));
        table.Declare("running_ms", "long", typeof(double));
        table.Declare("cancellable", "boolean", typeof(bool));
        table.Declare("parent_task_id", "keyword", typeof(string));
        foreach (var (key, task) in Tasks(response.RootElement))
        {
            table.NewRow();
            var node = Text(task, "node");
            var id = task.TryGetProperty("id", out var idValue) ? idValue.GetRawText() : null;
            table.Set("task_id", key ?? (node is not null && id is not null ? $"{node}:{id}" : null));
            table.Set("node", node);
            table.Set("action", Text(task, "action"));
            table.Set("type", Text(task, "type"));
            table.Set("description", Text(task, "description"));
            table.Set("start_time", task.TryGetProperty("start_time_in_millis", out var start) ? DateTimeOffset.FromUnixTimeMilliseconds(start.GetInt64()) : null);
            table.Set("running_ms", task.TryGetProperty("running_time_in_nanos", out var nanos) ? nanos.GetDouble() / 1_000_000d : null);
            table.Set("cancellable", task.TryGetProperty("cancellable", out var cancellable) && cancellable.ValueKind == JsonValueKind.True);
            table.Set("parent_task_id", Text(task, "parent_task_id"));
        }

        return table.Build();
    }

    /// <summary><c>group_by=none</c> answers a list, older clusters an object keyed by task id, the default a tree by node.</summary>
    private static IEnumerable<(string? Key, JsonElement Task)> Tasks(JsonElement root)
    {
        if (root.TryGetProperty("tasks", out var tasks))
        {
            if (tasks.ValueKind == JsonValueKind.Array)
            {
                foreach (var task in tasks.EnumerateArray())
                {
                    yield return (null, task);
                }
            }
            else if (tasks.ValueKind == JsonValueKind.Object)
            {
                foreach (var task in tasks.EnumerateObject())
                {
                    yield return (task.Name, task.Value);
                }
            }
        }
        else if (root.TryGetProperty("nodes", out var nodes))
        {
            foreach (var node in nodes.EnumerateObject())
            {
                if (node.Value.TryGetProperty("tasks", out var nodeTasks))
                {
                    foreach (var task in nodeTasks.EnumerateObject())
                    {
                        yield return (task.Name, task.Value);
                    }
                }
            }
        }
    }

    public async Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        await Yield();
        var id = Convert.ToString(processId, CultureInfo.InvariantCulture) ?? throw new ArgumentException("No task id.", nameof(processId));
        using var _ = await RequestAsync(HttpMethod.Post, $"/_tasks/{EsWrites.Segment(id)}/_cancel", null, cancellationToken);
    }

    public async Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var settingsTask = RequestAsync(HttpMethod.Get, "/_cluster/settings?flat_settings=true", null, cancellationToken);
        var healthTask = RequestAsync(HttpMethod.Get, "/_cluster/health", null, cancellationToken);
        using var settings = await settingsTask;
        using var health = await healthTask;
        var rows = new List<object?[]>();
        foreach (var scope in settings.RootElement.EnumerateObject())
        {
            if (scope.Value.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            JsonCells.Flatten(scope.Value, string.Empty, (name, value) => rows.Add([scope.Name, name, Display(value)]));
        }

        foreach (var property in health.RootElement.EnumerateObject())
        {
            rows.Add(["health", property.Name, Display(property.Value)]);
        }

        return new ResultSet(
            [new ResultColumn("scope", "keyword", typeof(string)), new ResultColumn("name", "keyword", typeof(string)), new ResultColumn("value", "keyword", typeof(string))],
            rows);

        static string? Display(JsonElement value) => value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Null => null,
            _ => value.GetRawText(),
        };
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
            throw new ArgumentException("Enter a request like: GET /my-index/_search");
        }

        // A body on GET is legal for Elasticsearch, but proxies drop it, so a search with a body goes as POST.
        var method = block.Body is not null && block.Method is "GET" or "HEAD" ? "POST" : block.Method;
        var lower = block.Path.ToLowerInvariant();
        var ndjson = lower.Contains("_bulk", StringComparison.Ordinal) || lower.Contains("_msearch", StringComparison.Ordinal);
        var body = ndjson && block.Body is not null && !block.Body.EndsWith('\n') ? block.Body + "\n" : block.Body;
        var reply = await _transport.SendAsync(new HttpMethod(method), block.Path, body, cancellationToken, ndjson ? "application/x-ndjson" : "application/json");
        if (block.Method is not ("GET" or "HEAD"))
        {
            // Anything but a read may have changed a mapping; refilling costs one request per index reopened.
            _mappings.Clear();
        }

        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(EsErrors.Reason(reply), reply.StatusCode);
        }

        return EsResponses.Render(reply, options.RowLimit);
    }

    private async Task<IReadOnlyDictionary<string, EsField>> MappingAsync(string index, CancellationToken cancellationToken)
    {
        if (_mappings.TryGetValue(index, out var cached))
        {
            return cached;
        }

        using var response = await RequestAsync(HttpMethod.Get, $"/{EsWrites.Segment(index)}/_mapping", null, cancellationToken);
        var fields = EsMapping.Parse(response.RootElement, index).ToDictionary(f => f.Name, StringComparer.Ordinal);
        _mappings[index] = fields;
        return fields;
    }

    private static DocumentTable NewHitTable(IReadOnlyDictionary<string, EsField> fields)
    {
        var table = new DocumentTable();
        table.Declare(EsMapping.IdColumn, "keyword", typeof(string));
        table.Declare(EsMapping.IndexColumn, "keyword", typeof(string));
        foreach (var field in fields.Values.OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase))
        {
            table.Declare(field.Name, field.Type, field.ClrType);
        }

        return table;
    }

    internal static void AddHits(DocumentTable table, JsonElement response, IReadOnlyDictionary<string, EsField> fields, int limit)
    {
        var hits = Hits(response);
        if (hits.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var hit in hits.EnumerateArray())
        {
            if (table.RowCount >= limit)
            {
                return;
            }

            table.NewRow();
            table.Set(EsMapping.IdColumn, Text(hit, "_id"));
            table.Set(EsMapping.IndexColumn, Text(hit, "_index"));
            if (hit.TryGetProperty("_source", out var source))
            {
                SetSource(table, source, string.Empty, fields);
            }
        }
    }

    /// <summary>Flattens a source along the mapping, keeping an object-typed or nested field whole as one JSON cell.</summary>
    private static void SetSource(DocumentTable table, JsonElement value, string path, IReadOnlyDictionary<string, EsField> fields)
    {
        if (value.ValueKind == JsonValueKind.Object && (path.Length == 0 || !(fields.TryGetValue(path, out var field) && field.IsStructured)))
        {
            foreach (var property in value.EnumerateObject())
            {
                SetSource(table, property.Value, path.Length == 0 ? property.Name : $"{path}.{property.Name}", fields);
            }

            return;
        }

        table.Set(path, value);
    }

    internal static JsonElement Hits(JsonElement response) =>
        response.ValueKind == JsonValueKind.Object && response.TryGetProperty("hits", out var outer) && outer.ValueKind == JsonValueKind.Object && outer.TryGetProperty("hits", out var inner)
            ? inner
            : default;

    private Task<JsonDocument> RequestAsync(HttpMethod method, string path, string? body, CancellationToken cancellationToken) =>
        RequestAsync(_transport, method, path, body, cancellationToken);

    private static async Task<JsonDocument> RequestAsync(HttpTransport transport, HttpMethod method, string path, string? body, CancellationToken cancellationToken)
    {
        var reply = await transport.SendAsync(method, path, body, cancellationToken);
        if (!reply.IsSuccess)
        {
            throw new ServerRequestException(EsErrors.Reason(reply), reply.StatusCode);
        }

        return reply.TryParseJson() ?? JsonDocument.Parse("{}");
    }

    private async Task<JsonDocument?> TryRequestAsync(HttpMethod method, string path, CancellationToken cancellationToken, string? body = null)
    {
        try
        {
            var reply = await _transport.SendAsync(method, path, body, cancellationToken);
            return reply.IsSuccess ? reply.TryParseJson() : null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement element, string property) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(property, out var value)
            ? value.ValueKind == JsonValueKind.String ? value.GetString() : value.ValueKind == JsonValueKind.Null ? null : value.GetRawText()
            : null;

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}
