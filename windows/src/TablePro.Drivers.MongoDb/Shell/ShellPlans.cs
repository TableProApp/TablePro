using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>What a statement runs, decided without touching the server so it can be tested as data.</summary>
internal abstract record ShellPlan;

/// <summary>Changes the tab's database.</summary>
internal sealed record UsePlan(string Database) : ShellPlan;

/// <summary>A line of text, such as <c>db.getName()</c>.</summary>
internal sealed record MessagePlan(string Message) : ShellPlan;

/// <summary><c>show dbs</c>: the databases the login may see.</summary>
internal sealed record ListDatabasesPlan : ShellPlan;

internal sealed record ListCollectionsPlan(string Database, BsonDocument Filter, bool NamesOnly) : ShellPlan;

internal sealed record ListIndexesPlan(string Database, string Collection) : ShellPlan;

/// <summary>The options a find cursor collects from its arguments and the calls chained after it.</summary>
internal sealed class FindSpec
{
    public BsonDocument? Projection { get; set; }

    public BsonDocument? Sort { get; set; }

    public int? Skip { get; set; }

    public int? Limit { get; set; }

    public BsonValue? Hint { get; set; }

    public long? MaxTimeMs { get; set; }

    public int? BatchSize { get; set; }

    public BsonValue? Comment { get; set; }

    public BsonDocument? Collation { get; set; }

    public bool? AllowDiskUse { get; set; }

    /// <summary>The find as a command document, for <c>explain</c>.</summary>
    public BsonDocument ToCommand(string collection, BsonDocument filter)
    {
        var command = new BsonDocument { { "find", collection }, { "filter", filter } };
        command.AddRange(Options());
        return command;
    }

    public IEnumerable<BsonElement> Options()
    {
        if (Projection is not null)
        {
            yield return new BsonElement("projection", Projection);
        }

        if (Sort is not null)
        {
            yield return new BsonElement("sort", Sort);
        }

        if (Skip is { } skip)
        {
            yield return new BsonElement("skip", skip);
        }

        if (Limit is { } limit)
        {
            yield return new BsonElement("limit", limit);
        }

        if (Hint is not null)
        {
            yield return new BsonElement("hint", Hint);
        }

        if (MaxTimeMs is { } maxTime)
        {
            yield return new BsonElement("maxTimeMS", maxTime);
        }

        if (BatchSize is { } batch)
        {
            yield return new BsonElement("batchSize", batch);
        }

        if (Comment is not null)
        {
            yield return new BsonElement("comment", Comment);
        }

        if (Collation is not null)
        {
            yield return new BsonElement("collation", Collation);
        }

        if (AllowDiskUse is { } disk)
        {
            yield return new BsonElement("allowDiskUse", disk);
        }
    }
}

/// <summary>A <c>find</c> or <c>findOne</c> read through a cursor.</summary>
internal sealed record FindPlan(string Database, string Collection, BsonDocument Filter, FindSpec Spec, bool Single) : ShellPlan;

/// <summary>An aggregation on a collection, or on the database when <see cref="Collection"/> is null.</summary>
internal sealed record AggregatePlan(string Database, string? Collection, List<BsonDocument> Pipeline, BsonDocument Options) : ShellPlan;

/// <summary>How a command's reply becomes a result.</summary>
internal enum ReplyShape
{
    /// <summary>The reply as one row.</summary>
    Document,

    /// <summary>A row per document in the reply's <see cref="CommandPlan.Field"/> array.</summary>
    Rows,

    /// <summary>One value, the reply's <see cref="CommandPlan.Field"/>.</summary>
    Field,

    /// <summary>A row per value in the reply's <see cref="CommandPlan.Field"/> array, for <c>distinct</c>.</summary>
    Values,

    /// <summary>The reply's <c>n</c>, or the <c>n</c> of the first document of its cursor.</summary>
    Count,

    /// <summary>An insert, update or delete reply as a write result.</summary>
    Write,

    /// <summary>The document a <c>findAndModify</c> returned.</summary>
    FindAndModify,

    /// <summary>The documents of a reply's first cursor batch when it has one, else the reply as one row.</summary>
    Auto,
}

/// <summary>A database command run as is. <see cref="InsertedIds"/> are the ids an insert gave documents that had none.</summary>
internal sealed record CommandPlan(string Database, BsonDocument Command, ReplyShape Shape, string? Field = null, BsonArray? InsertedIds = null) : ShellPlan;

/// <summary>A <c>bulkWrite</c>: commands run in order, stopping at the first failure when ordered.</summary>
internal sealed record BatchPlan(IReadOnlyList<CommandPlan> Steps, bool Ordered) : ShellPlan;
