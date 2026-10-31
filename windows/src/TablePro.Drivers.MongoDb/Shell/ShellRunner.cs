using MongoDB.Bson;
using MongoDB.Driver;
using TablePro.Core.Results;
using TablePro.Drivers.MongoDb.Documents;
using TablePro.Drivers.MongoDb.Localization;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>Runs a plan against the server. Cursors read one document past the row limit to tell a cut result from a whole one.</summary>
internal sealed class ShellRunner(IMongoClient client)
{
    private static readonly string[] TimedCommands = ["aggregate", "count", "distinct", "find", "findAndModify"];

    public async Task<ShellOutcome> RunAsync(ShellPlan plan, ExecuteOptions options, CancellationToken cancellationToken) => plan switch
    {
        MessagePlan message => ShellOutcome.Message(message.Message),
        FindPlan find => await FindAsync(find, options, cancellationToken),
        AggregatePlan aggregate => await AggregateAsync(aggregate, options, cancellationToken),
        ListDatabasesPlan => await CommandAsync(
            new CommandPlan("admin", new BsonDocument { { "listDatabases", 1 }, { "authorizedDatabases", true } }, ReplyShape.Rows, "databases"), options, cancellationToken),
        ListCollectionsPlan list => await ListCollectionsAsync(list, options, cancellationToken),
        ListIndexesPlan indexes => await ListIndexesAsync(indexes, options, cancellationToken),
        CommandPlan command => await CommandAsync(command, options, cancellationToken),
        BatchPlan batch => await BatchAsync(batch, cancellationToken),
        _ => throw new ShellUnsupportedException(MongoStrings.Get("Mongo/StatementUnsupported")),
    };

    public static async Task<(List<BsonDocument> Documents, bool Truncated)> ReadAsync(IAsyncCursor<BsonDocument> cursor, int rowLimit, CancellationToken cancellationToken)
    {
        var documents = new List<BsonDocument>();
        while (await cursor.MoveNextAsync(cancellationToken))
        {
            foreach (var document in cursor.Current)
            {
                if (rowLimit > 0 && documents.Count >= rowLimit)
                {
                    return (documents, true);
                }

                documents.Add(document);
            }
        }

        return (documents, false);
    }

    private static TimeSpan? MaxTime(long? explicitMs, ExecuteOptions options) =>
        explicitMs is { } ms ? TimeSpan.FromMilliseconds(ms)
        : options.CommandTimeoutSeconds > 0 ? TimeSpan.FromSeconds(options.CommandTimeoutSeconds)
        : null;

    private async Task<ShellOutcome> FindAsync(FindPlan plan, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var spec = plan.Spec;
        var rowLimit = plan.Single ? 1 : options.RowLimit;
        int? limit = spec.Limit is { } l && l != 0 ? Math.Abs(l) : null;
        if (rowLimit > 0)
        {
            // One past the row limit tells a cut result from a whole one.
            limit = Math.Min(limit ?? int.MaxValue, rowLimit + 1);
        }

        var findOptions = new FindOptions<BsonDocument>
        {
            Skip = spec.Skip,
            Limit = limit,
            BatchSize = spec.BatchSize,
            Hint = spec.Hint,
            MaxTime = MaxTime(spec.MaxTimeMs, options),
            AllowDiskUse = spec.AllowDiskUse,
        };
        if (spec.Projection is not null)
        {
            findOptions.Projection = spec.Projection;
        }

        if (spec.Sort is not null)
        {
            findOptions.Sort = spec.Sort;
        }

        if (spec.Collation is not null)
        {
            findOptions.Collation = Collation.FromBsonDocument(spec.Collation);
        }

        if (spec.Comment is not null)
        {
            findOptions.Comment = spec.Comment;
        }

        var collection = client.GetDatabase(plan.Database).GetCollection<BsonDocument>(plan.Collection);
        using var cursor = await collection.FindAsync(new BsonDocumentFilterDefinition<BsonDocument>(plan.Filter), findOptions, cancellationToken);
        var (documents, truncated) = await ReadAsync(cursor, rowLimit, cancellationToken);
        if (plan.Single)
        {
            return documents.Count == 0 ? ShellOutcome.Message("null") : ShellOutcome.Of(DocumentResults.Build(documents, truncated: false));
        }

        return ShellOutcome.Of(DocumentResults.Build(documents, truncated));
    }

    private async Task<ShellOutcome> AggregateAsync(AggregatePlan plan, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var o = plan.Options;
        var aggregateOptions = new AggregateOptions
        {
            AllowDiskUse = o.TryGetValue("allowDiskUse", out var disk) && disk.IsBoolean ? disk.AsBoolean : null,
            MaxTime = MaxTime(o.TryGetValue("maxTimeMS", out var maxTime) && maxTime.IsNumeric ? maxTime.ToInt64() : null, options),
            Hint = o.GetValue("hint", null),
            Comment = o.GetValue("comment", null),
            Let = o.GetValue("let", null) as BsonDocument,
            BypassDocumentValidation = o.TryGetValue("bypassDocumentValidation", out var bypass) && bypass.IsBoolean ? bypass.AsBoolean : null,
        };
        if (o.GetValue("collation", null) is BsonDocument collation)
        {
            aggregateOptions.Collation = Collation.FromBsonDocument(collation);
        }

        if (o.GetValue("cursor", null) is BsonDocument cursorOptions && cursorOptions.GetValue("batchSize", null) is { IsNumeric: true } batch)
        {
            aggregateOptions.BatchSize = batch.ToInt32();
        }

        var database = client.GetDatabase(plan.Database);
        IAsyncCursor<BsonDocument> cursor = plan.Collection is null
            ? await database.AggregateAsync(PipelineDefinition<NoPipelineInput, BsonDocument>.Create(plan.Pipeline), aggregateOptions, cancellationToken)
            : await database.GetCollection<BsonDocument>(plan.Collection).AggregateAsync(PipelineDefinition<BsonDocument, BsonDocument>.Create(plan.Pipeline), aggregateOptions, cancellationToken);
        using (cursor)
        {
            var (documents, truncated) = await ReadAsync(cursor, options.RowLimit, cancellationToken);
            return ShellOutcome.Of(DocumentResults.Build(documents, truncated));
        }
    }

    private async Task<ShellOutcome> ListCollectionsAsync(ListCollectionsPlan plan, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var database = client.GetDatabase(plan.Database);
        if (plan.NamesOnly)
        {
            using var names = await database.ListCollectionNamesAsync(
                new ListCollectionNamesOptions { Filter = plan.Filter, AuthorizedCollections = true }, cancellationToken);
            var list = await names.ToListAsync(cancellationToken);
            list.Sort(StringComparer.Ordinal);
            return ShellOutcome.Of(DocumentResults.Values("name", list.Select(n => (BsonValue)n)));
        }

        using var cursor = await database.ListCollectionsAsync(new ListCollectionsOptions { Filter = plan.Filter }, cancellationToken);
        var (documents, truncated) = await ReadAsync(cursor, options.RowLimit, cancellationToken);
        return ShellOutcome.Of(DocumentResults.Build(documents, truncated));
    }

    private async Task<ShellOutcome> ListIndexesAsync(ListIndexesPlan plan, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var collection = client.GetDatabase(plan.Database).GetCollection<BsonDocument>(plan.Collection);
        using var cursor = await collection.Indexes.ListAsync(cancellationToken);
        var (documents, truncated) = await ReadAsync(cursor, options.RowLimit, cancellationToken);
        return ShellOutcome.Of(DocumentResults.Build(documents, truncated, ["v", "key", "name"]));
    }

    private async Task<ShellOutcome> CommandAsync(CommandPlan plan, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var command = plan.Command;
        if (options.CommandTimeoutSeconds > 0 && !command.Contains("maxTimeMS") && TimedCommands.Contains(command.GetElement(0).Name, StringComparer.Ordinal))
        {
            command = new BsonDocument(command) { { "maxTimeMS", options.CommandTimeoutSeconds * 1000L } };
        }

        var reply = await RunCommandAsync(plan.Database, command, cancellationToken);
        return ReplyResults.FromReply(plan, reply, options.RowLimit);
    }

    private async Task<ShellOutcome> BatchAsync(BatchPlan plan, CancellationToken cancellationToken)
    {
        var tally = new WriteTally();
        var errors = new List<string>();
        foreach (var step in plan.Steps)
        {
            try
            {
                var reply = await RunCommandAsync(step.Database, step.Command, cancellationToken);
                tally.Add(step.Command, reply, step.InsertedIds);
            }
            catch (Exception ex) when (!plan.Ordered && ex is ShellWriteException or MongoException)
            {
                errors.Add(ex.Message);
            }
        }

        if (errors.Count > 0)
        {
            throw new ShellWriteException(MongoStrings.Format("Mongo/OperationsFailed", errors.Count, plan.Steps.Count, string.Join("; ", errors)));
        }

        return ShellOutcome.Of(tally.ToResult(), tally.Affected);
    }

    private Task<BsonDocument> RunCommandAsync(string database, BsonDocument command, CancellationToken cancellationToken) =>
        client.GetDatabase(database).RunCommandAsync(new BsonDocumentCommand<BsonDocument>(command), ReadPreference.Primary, cancellationToken);
}
