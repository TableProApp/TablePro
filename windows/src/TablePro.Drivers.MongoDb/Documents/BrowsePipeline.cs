using MongoDB.Bson;
using TablePro.Core.Browse;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>The aggregation a table tab runs for one page of a collection.</summary>
internal static class BrowsePipeline
{
    public static List<BsonDocument> Build(BrowseRequest request, CollectionSchema schema)
    {
        var stages = new List<BsonDocument>(5);
        var match = MongoFilter.Build(request.Filter, schema);
        if (match.ElementCount > 0)
        {
            stages.Add(new BsonDocument("$match", match));
        }

        stages.Add(new BsonDocument("$sort", Sort(request.Sort)));
        if (request.Offset > 0)
        {
            stages.Add(new BsonDocument("$skip", request.Offset));
        }

        if (request.Limit > 0)
        {
            stages.Add(new BsonDocument("$limit", request.Limit));
        }

        if (Projection(schema) is { } projection)
        {
            stages.Add(new BsonDocument("$project", projection));
        }

        return stages;
    }

    /// <summary>The user's sort, then <c>_id</c>, so pages that skip past each other never repeat or miss a document.</summary>
    public static BsonDocument Sort(IReadOnlyList<SortColumn> sort)
    {
        var document = new BsonDocument();
        foreach (var column in sort)
        {
            if (!column.Column.StartsWith('$') && !document.Contains(column.Column))
            {
                document.Add(column.Column, column.Descending ? -1 : 1);
            }
        }

        if (!document.Contains("_id"))
        {
            document.Add("_id", 1);
        }

        return document;
    }

    // Only the fields the grid shows cross the wire. A field whose name holds a dot or starts with $ cannot be named in
    // a projection, so such a collection is read whole.
    private static BsonDocument? Projection(CollectionSchema schema)
    {
        var projection = new BsonDocument();
        foreach (var column in schema.Columns)
        {
            if (column.Name.StartsWith('$') || column.Name.Contains('.', StringComparison.Ordinal) || column.Name.Length == 0)
            {
                return null;
            }

            projection.Add(column.Name, 1);
        }

        return projection.ElementCount == 0 ? null : projection;
    }
}
