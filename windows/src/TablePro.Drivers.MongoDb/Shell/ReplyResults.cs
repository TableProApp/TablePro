using MongoDB.Bson;
using TablePro.Core.Results;
using TablePro.Drivers.MongoDb.Documents;
using TablePro.Drivers.MongoDb.Localization;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>What a statement showed: its result sets, the documents it changed and any lines of text.</summary>
internal sealed record ShellOutcome(IReadOnlyList<ResultSet> ResultSets, int RecordsAffected, IReadOnlyList<string> Messages)
{
    public static ShellOutcome Of(ResultSet result, int affected = 0) => new([result], affected, []);

    public static ShellOutcome Message(string message) => new([], 0, [message]);
}

/// <summary>The counts a write reply carries, added up across the steps of a bulk write.</summary>
internal sealed class WriteTally
{
    public long Inserted { get; private set; }

    public long Matched { get; private set; }

    public long Modified { get; private set; }

    public long Upserted { get; private set; }

    public long Deleted { get; private set; }

    public BsonArray InsertedIds { get; } = [];

    public BsonArray UpsertedIds { get; } = [];

    public int Affected => (int)Math.Min(int.MaxValue, Inserted + Modified + Upserted + Deleted);

    /// <summary>Adds an insert, update or delete reply. A reply that carries write errors throws with the first.</summary>
    public void Add(BsonDocument command, BsonDocument reply, BsonArray? insertedIds)
    {
        if (reply.TryGetValue("writeErrors", out var errors) && errors is BsonArray { Count: > 0 } list)
        {
            var first = list[0] as BsonDocument;
            throw new ShellWriteException(
                MongoStrings.Format("Mongo/ErrorWithCode", first?.GetValue("errmsg", BsonNull.Value) is { IsString: true } errmsg ? errmsg.AsString : MongoStrings.Get("Mongo/WriteFailed"), first?.GetValue("code", BsonNull.Value)),
                first?.GetValue("index", 0).ToInt32() ?? 0);
        }

        if (reply.TryGetValue("writeConcernError", out var concern) && concern is BsonDocument concernError)
        {
            throw new ShellWriteException(MongoStrings.Format("Mongo/ConcernNotMet", ReplyResults.ServerMessage(concernError)), 0);
        }

        var n = reply.GetValue("n", 0).ToInt64();
        switch (command.GetElement(0).Name)
        {
            case "insert":
                Inserted += n;
                if (insertedIds is not null)
                {
                    InsertedIds.AddRange(insertedIds.Take((int)Math.Min(n, insertedIds.Count)));
                }

                break;
            case "update":
                var upserted = reply.GetValue("upserted", new BsonArray()) as BsonArray ?? [];
                Upserted += upserted.Count;
                Matched += n - upserted.Count;
                Modified += reply.GetValue("nModified", 0).ToInt64();
                foreach (var item in upserted)
                {
                    if (item is BsonDocument entry && entry.TryGetValue("_id", out var id))
                    {
                        UpsertedIds.Add(id);
                    }
                }

                break;
            case "delete":
                Deleted += n;
                break;
        }
    }

    /// <summary>One row, as mongosh prints a write: acknowledged and each count.</summary>
    public ResultSet ToResult()
    {
        ResultColumn[] columns =
        [
            new("acknowledged", "bool", typeof(bool)),
            new("insertedCount", "long", typeof(long)),
            new("matchedCount", "long", typeof(long)),
            new("modifiedCount", "long", typeof(long)),
            new("upsertedCount", "long", typeof(long)),
            new("deletedCount", "long", typeof(long)),
            new("insertedIds", "array", typeof(string)),
            new("upsertedIds", "array", typeof(string)),
        ];
        object?[] row =
        [
            true, Inserted, Matched, Modified, Upserted, Deleted,
            InsertedIds.Count == 0 ? null : ExtendedJson.Write(InsertedIds),
            UpsertedIds.Count == 0 ? null : ExtendedJson.Write(UpsertedIds),
        ];
        return new ResultSet(columns, [row]);
    }
}

/// <summary>A write the server refused, such as a duplicate key.</summary>
public sealed class ShellWriteException : InvalidOperationException
{
    public ShellWriteException()
    {
    }

    public ShellWriteException(string message)
        : base(message)
    {
    }

    public ShellWriteException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    internal ShellWriteException(string message, int index)
        : base(message)
    {
        Index = index;
    }

    /// <summary>The position of the failed document or statement in the command.</summary>
    public int Index { get; }
}

/// <summary>Turns a command's reply into what the editor shows, as its <see cref="ReplyShape"/> says.</summary>
internal static class ReplyResults
{
    /// <summary>The server's own <c>errmsg</c>, passed through as sent, or a translated stand-in when it gave none.</summary>
    public static string ServerMessage(BsonDocument error) =>
        error.GetValue("errmsg", BsonNull.Value) is { IsString: true } message ? message.AsString : MongoStrings.Get("Mongo/UnknownError");

    public static ShellOutcome FromReply(CommandPlan plan, BsonDocument reply, int rowLimit)
    {
        switch (plan.Shape)
        {
            case ReplyShape.Write:
                var tally = new WriteTally();
                tally.Add(plan.Command, reply, plan.InsertedIds);
                return ShellOutcome.Of(tally.ToResult(), tally.Affected);
            case ReplyShape.Count:
                return ShellOutcome.Of(Count(reply));
            case ReplyShape.Field:
                var field = plan.Field ?? "value";
                return ShellOutcome.Of(DocumentResults.Values(field, [reply.GetValue(field, BsonNull.Value)]));
            case ReplyShape.Values:
                var values = reply.GetValue(plan.Field ?? "values", new BsonArray()) as BsonArray ?? [];
                return ShellOutcome.Of(Limit(values, rowLimit, list => DocumentResults.Values("value", list)));
            case ReplyShape.Rows:
                var rows = reply.GetValue(plan.Field ?? "rows", new BsonArray()) as BsonArray ?? [];
                return ShellOutcome.Of(Limit(rows.OfType<BsonDocument>().ToList(), rowLimit, list => DocumentResults.Build(list, truncated: false)));
            case ReplyShape.FindAndModify:
                var affected = reply.GetValue("lastErrorObject", new BsonDocument()) is BsonDocument last ? last.GetValue("n", 0).ToInt32() : 0;
                return reply.GetValue("value", BsonNull.Value) is BsonDocument value
                    ? ShellOutcome.Of(DocumentResults.Build([value], truncated: false), affected)
                    : new ShellOutcome([], affected, [MongoStrings.Get("Mongo/NoDocumentMatched")]);
            case ReplyShape.Auto when reply.GetValue("cursor", BsonNull.Value) is BsonDocument cursor && cursor.GetValue("firstBatch", BsonNull.Value) is BsonArray batch:
                // Only the first batch is shown: a command's cursor is read through its own method, such as find().
                var documents = batch.OfType<BsonDocument>().ToList();
                var more = cursor.GetValue("id", 0).ToInt64() != 0;
                var shown = Limit(documents, rowLimit, list => DocumentResults.Build(list, more));
                return more ? new ShellOutcome([shown], 0, [MongoStrings.Get("Mongo/MoreThanFirstBatch")]) : ShellOutcome.Of(shown);
            default:
                return ShellOutcome.Of(DocumentResults.Build([reply], truncated: false));
        }
    }

    /// <summary>The count a command returned: its <c>n</c>, or the <c>n</c> of its cursor's first document.</summary>
    public static ResultSet Count(BsonDocument reply)
    {
        long count = 0;
        if (reply.TryGetValue("n", out var n) && n.IsNumeric)
        {
            count = n.ToInt64();
        }
        else if (reply.GetValue("cursor", BsonNull.Value) is BsonDocument cursor
            && cursor.GetValue("firstBatch", BsonNull.Value) is BsonArray { Count: > 0 } batch
            && batch[0] is BsonDocument first && first.TryGetValue("n", out var counted) && counted.IsNumeric)
        {
            count = counted.ToInt64();
        }

        return new ResultSet([new ResultColumn("count", "long", typeof(long))], [[count]]);
    }

    private static ResultSet Limit<T>(IList<T> items, int rowLimit, Func<IReadOnlyList<T>, ResultSet> build)
    {
        if (rowLimit <= 0 || items.Count <= rowLimit)
        {
            return build(items as IReadOnlyList<T> ?? items.ToList());
        }

        var kept = build(items.Take(rowLimit).ToList());
        return new ResultSet(kept.Columns, kept.Rows.ToList(), isTruncated: true);
    }
}
