using System.Text;
using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>
/// The mongosh script that recreates a collection: its options and validator through <c>createCollection</c>, or a
/// view through <c>createView</c>, then each index but <c>_id</c>'s. The script runs in mongosh and in the editor alike.
/// </summary>
internal static class CollectionScript
{
    // Options the server reports that createCollection does not take back.
    private static readonly HashSet<string> ServerOnlyOptions = new(StringComparer.Ordinal) { "uuid" };

    private static readonly HashSet<string> IndexKeysLeftOut = new(StringComparer.Ordinal) { "v", "key", "ns", "name" };

    /// <param name="info">The collection's <c>listCollections</c> entry: name, type and options.</param>
    /// <param name="indexes">Its <c>listIndexes</c> entries.</param>
    public static string Build(BsonDocument info, IReadOnlyList<BsonDocument> indexes)
    {
        var name = info.GetValue("name", string.Empty).ToString()!;
        var type = info.GetValue("type", "collection").ToString();
        var options = info.GetValue("options", new BsonDocument()) as BsonDocument ?? [];
        var sb = new StringBuilder();
        if (type == "view")
        {
            var rest = new BsonDocument();
            foreach (var option in options)
            {
                if (option.Name is not ("viewOn" or "pipeline"))
                {
                    rest.Add(option);
                }
            }

            sb.Append("db.createView(");
            ExtendedJson.AppendString(sb, name);
            sb.Append(", ");
            ExtendedJson.AppendString(sb, options.GetValue("viewOn", string.Empty).ToString()!);
            sb.Append(", ");
            ExtendedJson.Append(sb, options.GetValue("pipeline", new BsonArray()), JsonFlavor.Shell, 0);
            if (rest.ElementCount > 0)
            {
                sb.Append(", ");
                ExtendedJson.Append(sb, rest, JsonFlavor.Shell, 0);
            }

            return sb.Append(");\n").ToString();
        }

        var kept = new BsonDocument();
        foreach (var option in options)
        {
            if (!ServerOnlyOptions.Contains(option.Name))
            {
                kept.Add(option);
            }
        }

        sb.Append("db.createCollection(");
        ExtendedJson.AppendString(sb, name);
        if (kept.ElementCount > 0)
        {
            sb.Append(", ");
            ExtendedJson.Append(sb, kept, JsonFlavor.Shell, 0);
        }

        sb.Append(");\n");
        foreach (var index in indexes)
        {
            var indexName = index.GetValue("name", string.Empty).ToString();

            // Every collection gets _id's index, and a clustered collection's key is its createCollection option.
            if (indexName == "_id_" || index.GetValue("clustered", false).ToBoolean())
            {
                continue;
            }

            var indexOptions = new BsonDocument("name", indexName);
            foreach (var element in index)
            {
                if (!IndexKeysLeftOut.Contains(element.Name))
                {
                    indexOptions.Add(element);
                }
            }

            sb.Append("db.getCollection(");
            ExtendedJson.AppendString(sb, name);
            sb.Append(").createIndex(");
            ExtendedJson.Append(sb, index.GetValue("key", new BsonDocument()), JsonFlavor.Shell, -1);
            sb.Append(", ");
            ExtendedJson.Append(sb, indexOptions, JsonFlavor.Shell, -1);
            sb.Append(");\n");
        }

        return sb.ToString();
    }

    public static string CreateDatabase(string name)
    {
        // A database exists once it holds a collection, so creating one creates its first collection, named after it.
        var sb = new StringBuilder("db.getSiblingDB(");
        ExtendedJson.AppendString(sb, name);
        sb.Append(").createCollection(");
        ExtendedJson.AppendString(sb, name);
        return sb.Append(')').ToString();
    }

    public static string DropDatabase(string name)
    {
        var sb = new StringBuilder("db.getSiblingDB(");
        ExtendedJson.AppendString(sb, name);
        return sb.Append(").dropDatabase()").ToString();
    }
}
