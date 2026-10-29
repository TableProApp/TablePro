using System.Text;
using MongoDB.Bson;
using TablePro.Core.Editing;
using TablePro.Drivers.MongoDb.Localization;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>One single-document write a save sends, with the mongosh text that does the same for errors and history.</summary>
internal sealed record WriteStep(BsonDocument Command, string Shell);

/// <summary>
/// Turns the grid's edits into write commands: an edit is an <c>update</c> of the one document <c>_id</c> names with
/// <c>$set</c>, a new row an <c>insert</c> that leaves <c>_id</c> to the server unless one was typed, a delete a
/// <c>delete</c> limited to one document. Each must reach exactly one document.
/// </summary>
internal static class ChangeCommands
{
    public static WriteStep Build(string collection, RowChange change, CollectionSchema schema) => change switch
    {
        RowUpdate update => Update(collection, update, schema),
        RowInsert insert => Insert(collection, insert, schema),
        RowDelete delete => Delete(collection, delete, schema),
        _ => throw new NotSupportedException(MongoStrings.Format("Mongo/NotAChange", change.GetType().Name)),
    };

    public static BsonDocument Filter(IReadOnlyDictionary<string, object?> key, CollectionSchema schema)
    {
        // _id names one document; the other columns of the row would only make a stale grid miss it.
        if (key.TryGetValue("_id", out var id))
        {
            return new BsonDocument("_id", DocumentCells.FromCell(id, schema.Find("_id")));
        }

        var filter = new BsonDocument();
        foreach (var (name, value) in key)
        {
            filter.Add(name, DocumentCells.FromCell(value, schema.Find(name)));
        }

        return filter;
    }

    /// <summary>The number of documents a write command reached, from its reply, or an error the reply carries.</summary>
    public static int Affected(BsonDocument reply, string shell)
    {
        if (reply.TryGetValue("writeErrors", out var errors) && errors is BsonArray { Count: > 0 } list)
        {
            var first = list[0] as BsonDocument;
            var message = first?.GetValue("errmsg", BsonNull.Value) is { IsString: true } errmsg ? errmsg.AsString : MongoStrings.Get("Mongo/WriteFailed");
            var code = first?.GetValue("code", BsonNull.Value);
            throw new InvalidOperationException(MongoStrings.Format("Mongo/ErrorWithStatement", message, code, shell));
        }

        if (reply.TryGetValue("writeConcernError", out var concern) && concern is BsonDocument concernError)
        {
            throw new InvalidOperationException(MongoStrings.Format("Mongo/ConcernUnknownWithStatement", ReplyResults.ServerMessage(concernError), shell));
        }

        return reply.TryGetValue("n", out var n) && n.IsNumeric ? n.ToInt32() : 0;
    }

    private static WriteStep Update(string collection, RowUpdate update, CollectionSchema schema)
    {
        if (update.Values.ContainsKey("_id"))
        {
            throw new InvalidOperationException(MongoStrings.Get("Mongo/IdImmutable"));
        }

        var filter = Filter(update.Key, schema);
        var set = new BsonDocument();
        foreach (var (name, value) in update.Values)
        {
            set.Add(name, DocumentCells.FromCell(value, schema.Find(name)));
        }

        var change = new BsonDocument("$set", set);
        var command = new BsonDocument
        {
            { "update", collection },
            { "updates", new BsonArray { new BsonDocument { { "q", filter }, { "u", change }, { "multi", false }, { "upsert", false } } } },
            { "ordered", true },
        };
        return new WriteStep(command, Shell(collection, "updateOne", filter, change));
    }

    private static WriteStep Insert(string collection, RowInsert insert, CollectionSchema schema)
    {
        var document = new BsonDocument();
        if (insert.Values.TryGetValue("_id", out var id) && id is not null)
        {
            document.Add("_id", DocumentCells.FromCell(id, schema.Find("_id")));
        }

        // Columns in the order the grid shows them, then any the structure does not know.
        foreach (var column in schema.Columns)
        {
            if (column.Name != "_id" && insert.Values.TryGetValue(column.Name, out var value))
            {
                document.Add(column.Name, DocumentCells.FromCell(value, column));
            }
        }

        foreach (var (name, value) in insert.Values)
        {
            if (name != "_id" && !document.Contains(name))
            {
                document.Add(name, DocumentCells.FromCell(value, null));
            }
        }

        var command = new BsonDocument
        {
            { "insert", collection },
            { "documents", new BsonArray { document } },
            { "ordered", true },
        };
        return new WriteStep(command, Shell(collection, "insertOne", document));
    }

    private static WriteStep Delete(string collection, RowDelete delete, CollectionSchema schema)
    {
        var filter = Filter(delete.Key, schema);
        var command = new BsonDocument
        {
            { "delete", collection },
            { "deletes", new BsonArray { new BsonDocument { { "q", filter }, { "limit", 1 } } } },
            { "ordered", true },
        };
        return new WriteStep(command, Shell(collection, "deleteOne", filter));
    }

    public static string Shell(string collection, string method, params BsonValue[] arguments)
    {
        var sb = new StringBuilder("db.getCollection(");
        ExtendedJson.AppendString(sb, collection);
        sb.Append(").").Append(method).Append('(');
        for (var i = 0; i < arguments.Length; i++)
        {
            if (i > 0)
            {
                sb.Append(", ");
            }

            ExtendedJson.Append(sb, arguments[i], JsonFlavor.Shell, -1);
        }

        return sb.Append(')').ToString();
    }
}
