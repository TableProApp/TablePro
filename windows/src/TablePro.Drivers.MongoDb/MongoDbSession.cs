using System.Collections.Concurrent;
using MongoDB.Bson;
using MongoDB.Driver;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.MongoDb.Documents;

namespace TablePro.Drivers.MongoDb;

/// <summary>
/// A MongoDB connection. Databases are the sidebar's schemas, collections and views its objects, and a collection's
/// top-level fields its columns. Every call goes through one client, whose pool the driver keeps.
/// </summary>
public sealed class MongoDbSession : IDatabaseSession, IServerActivityProvider, IServerVariablesProvider, IUserListProvider, IDatabaseAdministration, IChangePreviewProvider
{
    private const int UnauthorizedCode = 13;
    private const int CountConcurrency = 8;
    private static readonly string[] SystemDatabases = ["admin", "config", "local"];
    private static readonly string[] ActivityColumns = ["opid", "active", "op", "ns", "secs_running", "client", "appName", "desc", "command"];

    private readonly ConcurrentDictionary<ObjectName, CollectionSchema> _schemas = new();
    private readonly ConnectionRequest _request;
    private MongoClient? _client;
    private bool _supportsTransactions;

    internal MongoDbSession(ConnectionRequest request)
    {
        _request = request;
        Profile = request.Profile;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => MongoDialect.Instance;

    public string ServerVersion { get; private set; } = string.Empty;

    public string? CurrentDatabase { get; private set; }

    public string? DefaultSchema => CurrentDatabase;

    public string ProcessIdColumn => "opid";

    private MongoClient Client => _client ?? throw new ObjectDisposedException(nameof(MongoDbSession));

    internal async Task InitializeAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        _client = new MongoClient(MongoClientSettingsFactory.Build(_request));
        var admin = _client.GetDatabase("admin");

        // The first command selects a server and logs in, so a refused password or a failed handshake fails the connect.
        BsonDocument hello;
        try
        {
            hello = await admin.RunCommandAsync<BsonDocument>(new BsonDocument("hello", 1), cancellationToken: cancellationToken);
        }
        catch (MongoCommandException)
        {
            hello = await admin.RunCommandAsync<BsonDocument>(new BsonDocument("isMaster", 1), cancellationToken: cancellationToken);
        }

        _supportsTransactions = SupportsTransactions(hello);
        try
        {
            var build = await admin.RunCommandAsync<BsonDocument>(new BsonDocument("buildInfo", 1), cancellationToken: cancellationToken);
            ServerVersion = build.GetValue("version", string.Empty).ToString() ?? string.Empty;
        }
        catch (MongoCommandException)
        {
            ServerVersion = string.Empty;
        }

        CurrentDatabase = string.IsNullOrWhiteSpace(_request.Database) ? await DefaultDatabaseAsync(cancellationToken) : _request.Database;
    }

    /// <summary>A replica set from MongoDB 4.0 and a sharded cluster from 4.2 run multi-document transactions.</summary>
    internal static bool SupportsTransactions(BsonDocument hello)
    {
        var wire = hello.GetValue("maxWireVersion", 0).ToInt32();
        var sharded = hello.GetValue("msg", string.Empty).ToString() == "isdbgrid";
        var replicaSet = hello.Contains("setName");
        return (replicaSet && wire >= 7) || (sharded && wire >= 8);
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        await Client.GetDatabase("admin").RunCommandAsync<BsonDocument>(new BsonDocument("ping", 1), cancellationToken: cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => DatabaseNamesAsync(cancellationToken);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => DatabaseNamesAsync(cancellationToken);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var databaseName = schema ?? CurrentDatabase ?? "test";
        var database = Client.GetDatabase(databaseName);
        var entries = new List<(string Name, string Type)>();
        try
        {
            using var cursor = await database.ListCollectionsAsync(cancellationToken: cancellationToken);
            await cursor.ForEachAsync(d => entries.Add((d.GetValue("name", string.Empty).ToString()!, d.GetValue("type", "collection").ToString()!)), cancellationToken);
        }
        catch (MongoCommandException ex) when (ex.Code == UnauthorizedCode)
        {
            // A login limited to some collections may list only those, by name.
            using var names = await database.ListCollectionNamesAsync(new ListCollectionNamesOptions { AuthorizedCollections = true }, cancellationToken);
            foreach (var name in await names.ToListAsync(cancellationToken))
            {
                entries.Add((name, "collection"));
            }
        }

        entries.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
        var counts = new long?[entries.Count];
        using var gate = new SemaphoreSlim(CountConcurrency);
        await Task.WhenAll(entries.Select(async (entry, index) =>
        {
            // A view's count would run its whole pipeline, so only collections are counted, from their metadata.
            if (entry.Type == "view")
            {
                return;
            }

            await gate.WaitAsync(cancellationToken);
            try
            {
                var reply = await database.RunCommandAsync<BsonDocument>(new BsonDocument("count", entry.Name), cancellationToken: cancellationToken);
                counts[index] = reply.GetValue("n", 0).ToInt64();
            }
            catch (MongoException)
            {
                counts[index] = null;
            }
            finally
            {
                gate.Release();
            }
        }));

        var objects = new DatabaseObject[entries.Count];
        for (var i = 0; i < entries.Count; i++)
        {
            var (name, type) = entries[i];
            objects[i] = new DatabaseObject(new ObjectName(databaseName, name), type == "view" ? ObjectKind.View : ObjectKind.Collection, counts[i], type == "collection" ? null : type);
        }

        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var schema = await InferSchemaAsync(table, cancellationToken);
        var indexes = new List<IndexInfo>();
        if (schema.Keyed || await CollectionTypeAsync(table, cancellationToken) != "view")
        {
            var collection = Collection(table);
            using var cursor = await collection.Indexes.ListAsync(cancellationToken);
            await cursor.ForEachAsync(index => indexes.Add(ToIndexInfo(index)), cancellationToken);
        }

        return new TableStructure(table, schema.ToColumnInfo(), indexes, [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var database = Client.GetDatabase(Database(obj.Name));
        using var cursor = await database.ListCollectionsAsync(new ListCollectionsOptions { Filter = new BsonDocument("name", obj.Name.Name) }, cancellationToken);
        var info = await cursor.FirstOrDefaultAsync(cancellationToken) ?? new BsonDocument { { "name", obj.Name.Name }, { "type", "collection" } };
        var indexes = new List<BsonDocument>();
        if (info.GetValue("type", "collection").ToString() != "view")
        {
            using var indexCursor = await Collection(obj.Name).Indexes.ListAsync(cancellationToken);
            indexes = await indexCursor.ToListAsync(cancellationToken);
        }

        return CollectionScript.Build(info, indexes);
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var schema = await SchemaAsync(request.Table, cancellationToken);
        var pipeline = BrowsePipeline.Build(request, schema);
        using var cursor = await Collection(request.Table).AggregateAsync(
            PipelineDefinition<BsonDocument, BsonDocument>.Create(pipeline),
            new AggregateOptions { AllowDiskUse = true },
            cancellationToken);
        var rows = new List<object?[]>(Math.Max(0, Math.Min(request.Limit, 10_000)));
        while (await cursor.MoveNextAsync(cancellationToken))
        {
            foreach (var document in cursor.Current)
            {
                rows.Add(DocumentCells.Flatten(document, schema.Columns));
            }
        }

        return new ResultSet(DocumentCells.ResultColumns(schema.Columns), rows);
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var schema = await SchemaAsync(table, cancellationToken);
        var query = MongoFilter.Build(filter, schema);
        return await Collection(table).CountDocumentsAsync(new BsonDocumentFilterDefinition<BsonDocument>(query), cancellationToken: cancellationToken);
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        if (changes.Count == 0)
        {
            return 0;
        }

        if (Profile.IsReadOnly)
        {
            throw new InvalidOperationException("The connection is read-only, so changes cannot be saved.");
        }

        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var schema = await SchemaAsync(table, cancellationToken);
        var steps = changes.Select(change => ChangeCommands.Build(table.Name, change, schema)).ToList();
        var database = Client.GetDatabase(Database(table));
        if (!_supportsTransactions)
        {
            // A standalone server has no transactions: each write applies on its own, in order, and the first that
            // misses its document stops the save.
            return await ApplyAsync(database, null, steps, cancellationToken);
        }

        using var session = await Client.StartSessionAsync(cancellationToken: cancellationToken);
        session.StartTransaction();
        try
        {
            var total = await ApplyAsync(database, session, steps, cancellationToken);
            await session.CommitTransactionAsync(cancellationToken);
            return total;
        }
        catch
        {
            if (session.IsInTransaction)
            {
                await session.AbortTransactionAsync(CancellationToken.None);
            }

            throw;
        }
    }

    public async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return new MongoQueryChannel(Client, CurrentDatabase ?? "test", Profile.IsReadOnly);
    }

    public async Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var reply = await Admin().RunCommandAsync<BsonDocument>(new BsonDocument("currentOp", 1), cancellationToken: cancellationToken);
        var operations = (reply.GetValue("inprog", new BsonArray()) as BsonArray ?? []).OfType<BsonDocument>().ToList();
        return DocumentResults.Build(operations, truncated: false, ActivityColumns);
    }

    public async Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        await Admin().RunCommandAsync<BsonDocument>(new BsonDocument { { "killOp", 1 }, { "op", OperationId(processId) } }, cancellationToken: cancellationToken);
    }

    /// <summary>A mongod names an operation by a number, a mongos by <c>shard:number</c> text.</summary>
    internal static BsonValue OperationId(object processId) => processId switch
    {
        int i => new BsonInt32(i),
        long l => new BsonInt64(l),
        double d when Math.Floor(d) == d => new BsonInt64((long)d),
        string s when long.TryParse(s, System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out var n) => n is >= int.MinValue and <= int.MaxValue ? new BsonInt32((int)n) : new BsonInt64(n),
        string s => new BsonString(s),
        _ => DocumentCells.FromCell(processId, null),
    };

    public async Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var status = await Admin().RunCommandAsync<BsonDocument>(new BsonDocument("serverStatus", 1), cancellationToken: cancellationToken);
        status.Remove("ok");
        return DocumentResults.NameValues(status);
    }

    public async Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        BsonDocument reply;
        try
        {
            reply = await Admin().RunCommandAsync<BsonDocument>(new BsonDocument("usersInfo", new BsonDocument("forAllDBs", true)), cancellationToken: cancellationToken);
        }
        catch (MongoCommandException ex) when (ex.Code == UnauthorizedCode)
        {
            // Without the right to see every database's users, a login still sees those of its own database.
            reply = await Client.GetDatabase(CurrentDatabase ?? "admin").RunCommandAsync<BsonDocument>(new BsonDocument("usersInfo", 1), cancellationToken: cancellationToken);
        }

        var users = (reply.GetValue("users", new BsonArray()) as BsonArray ?? []).OfType<BsonDocument>().ToList();
        return DocumentResults.Build(users, truncated: false, ["user", "db", "roles", "mechanisms"]);
    }

    /// <summary>
    /// The mongosh statements a save would run, one per change, for the review sheet; the SQL a relational preview
    /// writes would describe nothing MongoDB runs.
    /// </summary>
    public IReadOnlyList<string> PreviewChanges(ObjectName table, IReadOnlyList<RowChange> changes)
    {
        var schema = _schemas.TryGetValue(table, out var cached) ? cached : new CollectionSchema([], keyed: true);
        return changes.Select(change => ChangeCommands.Build(table.Name, change, schema).Shell).ToArray();
    }

    public string BuildCreateDatabase(string name) => CollectionScript.CreateDatabase(name);

    public string BuildDropDatabase(string name) => CollectionScript.DropDatabase(name);

    public ValueTask DisposeAsync()
    {
        // The client owns its pool and monitors; disposing it closes their sockets.
        _client?.Dispose();
        _client = null;
        return ValueTask.CompletedTask;
    }

    internal static IndexInfo ToIndexInfo(BsonDocument index)
    {
        var name = index.GetValue("name", string.Empty).ToString()!;
        var key = index.GetValue("key", new BsonDocument()) as BsonDocument ?? [];
        var columns = key.Names.ToArray();
        var kinds = key.Values.Where(v => v.IsString).Select(v => v.AsString).Distinct().ToArray();
        var primary = name == "_id_";
        return new IndexInfo(name, columns, primary || index.GetValue("unique", false).ToBoolean(), primary, kinds.Length == 0 ? null : string.Join(", ", kinds));
    }

    private static async Task<int> ApplyAsync(IMongoDatabase database, IClientSessionHandle? session, List<WriteStep> steps, CancellationToken cancellationToken)
    {
        var total = 0;
        foreach (var step in steps)
        {
            var command = new BsonDocumentCommand<BsonDocument>(step.Command);
            var reply = session is null
                ? await database.RunCommandAsync(command, ReadPreference.Primary, cancellationToken)
                : await database.RunCommandAsync(session, command, ReadPreference.Primary, cancellationToken);
            var affected = ChangeCommands.Affected(reply, step.Shell);
            if (affected != 1)
            {
                throw new RowCountMismatchException(1, affected, step.Shell);
            }

            total += affected;
        }

        return total;
    }

    private async Task<IReadOnlyList<string>> DatabaseNamesAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var names = new SortedSet<string>(StringComparer.Ordinal);
        try
        {
            using var cursor = await Client.ListDatabaseNamesAsync(new ListDatabaseNamesOptions { AuthorizedDatabases = true }, cancellationToken);
            foreach (var name in await cursor.ToListAsync(cancellationToken))
            {
                names.Add(name);
            }
        }
        catch (MongoCommandException ex) when (ex.Code == UnauthorizedCode)
        {
            // A login without listDatabases still works in the database it connected to.
        }

        // The connection's database belongs in the list before it holds a collection, as mongosh's `use` allows.
        if (CurrentDatabase is { } current)
        {
            names.Add(current);
        }

        return names.ToArray();
    }

    private async Task<string> DefaultDatabaseAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var cursor = await Client.ListDatabaseNamesAsync(new ListDatabaseNamesOptions { AuthorizedDatabases = true }, cancellationToken);
            var names = await cursor.ToListAsync(cancellationToken);
            names.Sort(StringComparer.Ordinal);
            return names.FirstOrDefault(n => !SystemDatabases.Contains(n, StringComparer.Ordinal)) ?? "test";
        }
        catch (MongoCommandException)
        {
            return "test";
        }
    }

    private async Task<CollectionSchema> SchemaAsync(ObjectName table, CancellationToken cancellationToken) =>
        _schemas.TryGetValue(table, out var cached) ? cached : await InferSchemaAsync(table, cancellationToken);

    private async Task<CollectionSchema> InferSchemaAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var collection = Collection(table);
        using var cursor = await collection.AggregateAsync(
            PipelineDefinition<BsonDocument, BsonDocument>.Create(FieldCensus.TallyPipeline()),
            new AggregateOptions { AllowDiskUse = true },
            cancellationToken);
        var tallies = await cursor.ToListAsync(cancellationToken);
        var type = await CollectionTypeAsync(table, cancellationToken);
        var schema = new CollectionSchema(FieldCensus.FromTallies(tallies).Columns(ensureId: true), keyed: type == "collection");
        _schemas[table] = schema;
        return schema;
    }

    private async Task<string> CollectionTypeAsync(ObjectName table, CancellationToken cancellationToken)
    {
        try
        {
            var database = Client.GetDatabase(Database(table));
            using var cursor = await database.ListCollectionsAsync(new ListCollectionsOptions { Filter = new BsonDocument("name", table.Name) }, cancellationToken);
            var info = await cursor.FirstOrDefaultAsync(cancellationToken);
            return info?.GetValue("type", "collection").ToString() ?? "collection";
        }
        catch (MongoCommandException ex) when (ex.Code == UnauthorizedCode)
        {
            return "collection";
        }
    }

    private string Database(ObjectName name) => string.IsNullOrEmpty(name.Schema) ? CurrentDatabase ?? "test" : name.Schema;

    private IMongoCollection<BsonDocument> Collection(ObjectName name) => Client.GetDatabase(Database(name)).GetCollection<BsonDocument>(name.Name);

    private IMongoDatabase Admin() => Client.GetDatabase("admin");
}
