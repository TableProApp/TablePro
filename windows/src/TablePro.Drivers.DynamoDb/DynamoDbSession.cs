using System.Buffers;
using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.DynamoDb.Localization;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// An AWS account's tables in one region, or DynamoDB Local. Tables are listed with ListTables and browsed with Scan;
/// the editor runs PartiQL through ExecuteStatement. The HTTP client is shared, so a channel holds no connection.
/// </summary>
public sealed class DynamoDbSession : IDatabaseSession
{
    private const int SampleSize = 200;
    private static readonly TimeSpan DescriptionLifetime = TimeSpan.FromSeconds(30);
    private readonly IDynamoDbApi _api;
    private readonly DynamoResumePoints _resumePoints = new();
    private readonly ConcurrentDictionary<string, (TableDescription Table, long Stamp)> _descriptions = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, string>> _attributeTypes = new(StringComparer.Ordinal);

    internal DynamoDbSession(ConnectionProfile profile, DynamoDbConnectionSettings settings, IDynamoDbApi api)
    {
        Profile = profile;
        Settings = settings;
        _api = api;
        ServerVersion = settings.ServiceUrl is null ? $"Amazon DynamoDB ({settings.Region})" : $"DynamoDB at {settings.ServiceUrl}";
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => PartiQlDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    public DynamoDbConnectionSettings Settings { get; }

    internal static async Task<DynamoDbSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var settings = DynamoDbConnectionSettings.From(request);
        var config = settings.CreateConfig();
        var credentials = settings.CreateCredentials();
        var client = credentials is null ? new AmazonDynamoDBClient(config) : new AmazonDynamoDBClient(credentials, config);
        var session = new DynamoDbSession(request.Profile, settings, new AmazonDynamoDbApi(client));
        try
        {
            // Proves the credentials, the region and the endpoint with the cheapest call that needs all three.
            await session._api.ListTablesAsync(new ListTablesRequest { Limit = 1 }, cancellationToken);
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        await _api.ListTablesAsync(new ListTablesRequest { Limit = 1 }, cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var tables = new List<DatabaseObject>();
        string? start = null;
        do
        {
            var response = await _api.ListTablesAsync(new ListTablesRequest { ExclusiveStartTableName = start }, cancellationToken);
            tables.AddRange((response.TableNames ?? []).Select(t => new DatabaseObject(new ObjectName(null, t), ObjectKind.Table)));
            start = string.IsNullOrEmpty(response.LastEvaluatedTableName) ? null : response.LastEvaluatedTableName;
        }
        while (start is not null);

        return tables;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var description = await DescribeAsync(table.Name, cancellationToken, refresh: true);
        var keys = KeysOf(description);
        var sample = await _api.ScanAsync(new ScanRequest { TableName = table.Name, Limit = SampleSize }, cancellationToken);
        return BuildStructure(table, description, keys, sample.Items ?? []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        return DescribeJson(await DescribeAsync(obj.Name.Name, cancellationToken, refresh: true));
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var description = await DescribeAsync(request.Table.Name, cancellationToken);
        var keys = KeysOf(description);
        var plan = DynamoFilterTranslator.Translate(request.Filter, keys.Types);
        var notices = new List<string>();
        if (request.Sort.Count > 0)
        {
            notices.Add(DynamoDbStrings.Get("DynamoDb/SortNotApplied"));
        }

        var page = await DynamoScanReader.ReadAsync(_api, request.Table.Name, keys.Names, plan, Math.Max(request.Offset, 0), Math.Max(request.Limit, 0), _resumePoints, cancellationToken);
        notices.AddRange(page.Notices);

        var result = DynamoItemTable.Build(page.Items, keys.Names, page.HasMore);
        RememberTypes(request.Table.Name, page.Items);
        return new ResultSet(result.Columns, [.. result.Rows], result.IsTruncated) { Notices = notices };
    }

    /// <summary>DescribeTable's ItemCount, which DynamoDB refreshes about every six hours. A filtered count would need a full scan, so it is unknown (-1).</summary>
    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        if (!filter.IsEmpty)
        {
            return -1;
        }

        var description = await DescribeAsync(table.Name, cancellationToken, refresh: true);
        return description.ItemCount ?? -1;
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        var description = await DescribeAsync(table.Name, cancellationToken);
        var keys = KeysOf(description);
        var items = DynamoSaveBuilder.Build(table.Name, keys, changes, _attributeTypes.GetValueOrDefault(table.Name));
        if (items.Count == 0)
        {
            return 0;
        }

        try
        {
            await _api.TransactWriteItemsAsync(new TransactWriteItemsRequest { TransactItems = items }, cancellationToken);
        }
        catch (TransactionCanceledException ex)
        {
            var reasons = ex.CancellationReasons ?? [];
            var failed = reasons.FindIndex(r => r.Code == "ConditionalCheckFailed");
            if (failed >= 0)
            {
                throw new RowCountMismatchException(1, 0, items[failed].Put is not null
                    ? DynamoDbStrings.Format("DynamoDb/ItemExists", failed + 1, items.Count)
                    : DynamoDbStrings.Format("DynamoDb/ItemGone", failed + 1, items.Count));
            }

            throw;
        }

        _resumePoints.Clear();
        return items.Count;
    }

    public async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        await Yield();
        return new DynamoDbQueryChannel(_api);
    }

    public ValueTask DisposeAsync()
    {
        _api.Dispose();
        return ValueTask.CompletedTask;
    }

    internal static DynamoKeySchema KeysOf(TableDescription description)
    {
        var types = (description.AttributeDefinitions ?? []).ToDictionary(a => a.AttributeName, a => a.AttributeType.Value, StringComparer.Ordinal);
        var schema = (description.KeySchema ?? []).OrderBy(k => k.KeyType == KeyType.HASH ? 0 : 1).ToList();
        if (schema.Count == 0)
        {
            throw new InvalidOperationException(DynamoDbStrings.Format("DynamoDb/NoKeySchema", description.TableName));
        }

        return new DynamoKeySchema([.. schema.Select(k => new KeyValuePair<string, string>(k.AttributeName, types.GetValueOrDefault(k.AttributeName, DynamoAttributeMapper.String)))]);
    }

    /// <summary>The key attributes, then every attribute the sampled items hold; indexes from the table's GSIs and LSIs.</summary>
    internal static TableStructure BuildStructure(ObjectName table, TableDescription description, DynamoKeySchema keys, IReadOnlyList<Dictionary<string, AttributeValue>> sample)
    {
        var columns = new List<ColumnInfo>();
        for (var i = 0; i < keys.Keys.Count; i++)
        {
            var (name, type) = keys.Keys[i];
            columns.Add(new ColumnInfo(name, $"{type} ({(i == 0 ? "partition key" : "sort key")})", false, null, true, false, columns.Count));
        }

        var types = DynamoItemTable.AttributeTypes(sample);
        foreach (var (name, seen) in types.Where(t => !keys.Types.ContainsKey(t.Key)).OrderBy(t => t.Key, StringComparer.Ordinal))
        {
            columns.Add(new ColumnInfo(name, seen.Count == 0 ? DynamoAttributeMapper.Null : string.Join('|', seen), true, null, false, false, columns.Count));
        }

        var indexes = new List<IndexInfo> { new("PRIMARY", keys.Names, true, true, keys.Keys.Count == 1 ? "HASH" : "HASH, RANGE") };
        indexes.AddRange((description.GlobalSecondaryIndexes ?? []).Select(g => new IndexInfo(
            g.IndexName, KeyNames(g.KeySchema), false, false, $"GSI ({g.Projection?.ProjectionType?.Value ?? "ALL"})")));
        indexes.AddRange((description.LocalSecondaryIndexes ?? []).Select(l => new IndexInfo(
            l.IndexName, KeyNames(l.KeySchema), false, false, $"LSI ({l.Projection?.ProjectionType?.Value ?? "ALL"})")));
        return new TableStructure(table, columns, indexes, [], []);
    }

    /// <summary>DynamoDB has no DDL; the definition is the table's description as JSON.</summary>
    internal static string DescribeJson(TableDescription table)
    {
        var buffer = new ArrayBufferWriter<byte>(1024);
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteString("TableName", table.TableName);
            writer.WriteString("TableStatus", table.TableStatus?.Value);
            writer.WriteString("BillingMode", table.BillingModeSummary?.BillingMode?.Value ?? "PROVISIONED");
            WriteKeySchema(writer, "KeySchema", table.KeySchema);
            writer.WriteStartArray("AttributeDefinitions");
            foreach (var attribute in table.AttributeDefinitions ?? [])
            {
                writer.WriteStartObject();
                writer.WriteString("AttributeName", attribute.AttributeName);
                writer.WriteString("AttributeType", attribute.AttributeType?.Value);
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            if (table.ProvisionedThroughput is { ReadCapacityUnits: > 0 } throughput)
            {
                writer.WriteStartObject("ProvisionedThroughput");
                writer.WriteNumber("ReadCapacityUnits", throughput.ReadCapacityUnits ?? 0);
                writer.WriteNumber("WriteCapacityUnits", throughput.WriteCapacityUnits ?? 0);
                writer.WriteEndObject();
            }

            WriteIndexes(writer, "GlobalSecondaryIndexes", (table.GlobalSecondaryIndexes ?? []).Select(g => (g.IndexName, g.KeySchema, g.Projection)));
            WriteIndexes(writer, "LocalSecondaryIndexes", (table.LocalSecondaryIndexes ?? []).Select(l => (l.IndexName, l.KeySchema, l.Projection)));
            if (table.StreamSpecification is { StreamEnabled: true } stream)
            {
                writer.WriteStartObject("StreamSpecification");
                writer.WriteBoolean("StreamEnabled", true);
                writer.WriteString("StreamViewType", stream.StreamViewType?.Value);
                writer.WriteEndObject();
            }

            if (table.ItemCount is { } count)
            {
                writer.WriteNumber("ItemCount", count);
            }

            if (table.TableSizeBytes is { } size)
            {
                writer.WriteNumber("TableSizeBytes", size);
            }

            if (table.TableArn is not null)
            {
                writer.WriteString("TableArn", table.TableArn);
            }

            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    private static void WriteIndexes(Utf8JsonWriter writer, string name, IEnumerable<(string Name, List<KeySchemaElement> Keys, Projection Projection)> indexes)
    {
        var list = indexes.ToList();
        if (list.Count == 0)
        {
            return;
        }

        writer.WriteStartArray(name);
        foreach (var (indexName, keys, projection) in list)
        {
            writer.WriteStartObject();
            writer.WriteString("IndexName", indexName);
            WriteKeySchema(writer, "KeySchema", keys);
            writer.WriteString("ProjectionType", projection?.ProjectionType?.Value ?? "ALL");
            if (projection?.NonKeyAttributes is { Count: > 0 } attributes)
            {
                writer.WriteStartArray("NonKeyAttributes");
                attributes.ForEach(writer.WriteStringValue);
                writer.WriteEndArray();
            }

            writer.WriteEndObject();
        }

        writer.WriteEndArray();
    }

    private static void WriteKeySchema(Utf8JsonWriter writer, string name, List<KeySchemaElement>? keys)
    {
        writer.WriteStartArray(name);
        foreach (var key in keys ?? [])
        {
            writer.WriteStartObject();
            writer.WriteString("AttributeName", key.AttributeName);
            writer.WriteString("KeyType", key.KeyType?.Value);
            writer.WriteEndObject();
        }

        writer.WriteEndArray();
    }

    private static List<string> KeyNames(List<KeySchemaElement>? keys) =>
        [.. (keys ?? []).OrderBy(k => k.KeyType == KeyType.HASH ? 0 : 1).Select(k => k.AttributeName)];

    // The SDK's HTTP calls may complete synchronously on a cached response path; the UI thread must never wait on them.
    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);

    private async Task<TableDescription> DescribeAsync(string table, CancellationToken cancellationToken, bool refresh = false)
    {
        if (!refresh && _descriptions.TryGetValue(table, out var cached) && Environment.TickCount64 - cached.Stamp < DescriptionLifetime.TotalMilliseconds)
        {
            return cached.Table;
        }

        var response = await _api.DescribeTableAsync(new DescribeTableRequest { TableName = table }, cancellationToken);
        _descriptions[table] = (response.Table, Environment.TickCount64);
        return response.Table;
    }

    // Edited text is written back as the type the attribute held, so a map stays a map and a number a Number.
    private void RememberTypes(string table, IReadOnlyList<Dictionary<string, AttributeValue>> items)
    {
        var types = DynamoItemTable.AttributeTypes(items)
            .Where(t => t.Value.Count == 1)
            .ToDictionary(t => t.Key, t => t.Value[0], StringComparer.Ordinal);
        _attributeTypes.AddOrUpdate(
            table,
            types,
            (_, previous) => previous.Concat(types).GroupBy(p => p.Key, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last().Value, StringComparer.Ordinal));
    }
}
