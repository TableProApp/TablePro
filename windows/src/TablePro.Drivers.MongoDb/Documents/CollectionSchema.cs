using MongoDB.Bson;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>
/// The columns a collection shows, inferred from its first documents. <see cref="Keyed"/> is false for a view or a
/// time-series collection, whose <c>_id</c> names no single document a write could reach.
/// </summary>
internal sealed class CollectionSchema
{
    private readonly Dictionary<string, FieldColumn> _byName;

    public CollectionSchema(IReadOnlyList<FieldColumn> columns, bool keyed)
    {
        Columns = columns;
        Keyed = keyed;
        _byName = new Dictionary<string, FieldColumn>(StringComparer.Ordinal);
        foreach (var column in columns)
        {
            _byName.TryAdd(column.Name, column);
        }
    }

    public IReadOnlyList<FieldColumn> Columns { get; }

    public bool Keyed { get; }

    public IReadOnlyDictionary<string, FieldColumn> ByName => _byName;

    public FieldColumn? Find(string name) => _byName.GetValueOrDefault(name);

    public IReadOnlyList<ColumnInfo> ToColumnInfo()
    {
        var result = new ColumnInfo[Columns.Count];
        for (var i = 0; i < Columns.Count; i++)
        {
            var column = Columns[i];
            var isId = column.Name == "_id";
            result[i] = new ColumnInfo(
                column.Name,
                column.DataType,
                IsNullable: !isId,
                DefaultValue: isId ? "ObjectId()" : null,
                IsPrimaryKey: isId && Keyed,
                IsIdentity: false,
                Ordinal: i + 1);
        }

        return result;
    }
}

/// <summary>Builds a grid result from documents a statement returned, a column per top-level field.</summary>
internal static class DocumentResults
{
    /// <summary>
    /// Columns are the union of the fields of the first 1,000 documents, <c>_id</c> first, then
    /// <paramref name="preferred"/> fields, then the rest in the order documents first show them.
    /// </summary>
    public static ResultSet Build(IReadOnlyList<BsonDocument> documents, bool truncated, IReadOnlyList<string>? preferred = null)
    {
        var columns = FieldCensus.FromDocuments(documents).Columns(ensureId: false);
        if (preferred is { Count: > 0 })
        {
            var rank = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var i = 0; i < preferred.Count; i++)
            {
                rank.TryAdd(preferred[i], i);
            }

            columns = columns
                .Select((column, index) => (column, index))
                .OrderBy(c => c.column.Name == "_id" ? -1 : rank.TryGetValue(c.column.Name, out var r) ? r : preferred.Count)
                .ThenBy(c => c.index)
                .Select(c => c.column)
                .ToArray();
        }

        var rows = new List<object?[]>(documents.Count);
        foreach (var document in documents)
        {
            rows.Add(DocumentCells.Flatten(document, columns));
        }

        return new ResultSet(DocumentCells.ResultColumns(columns), rows, truncated);
    }

    /// <summary>One column of scalar values, for <c>distinct</c> and name lists.</summary>
    public static ResultSet Values(string name, IEnumerable<BsonValue> values)
    {
        var list = values.ToList();
        var column = FieldCensus.Column(name, list.Select(FieldCensus.TypeName).ToHashSet(StringComparer.Ordinal));
        var rows = new List<object?[]>(list.Count);
        foreach (var value in list)
        {
            rows.Add([DocumentCells.ToCell(value, column)]);
        }

        return new ResultSet([column.ToResultColumn()], rows);
    }

    /// <summary>A document flattened to name and value rows, nested documents as dotted paths, for serverStatus.</summary>
    public static ResultSet NameValues(BsonDocument document, string nameColumn = "Variable", string valueColumn = "Value")
    {
        var rows = new List<object?[]>();
        AppendPaths(rows, document, prefix: null);
        return new ResultSet([new ResultColumn(nameColumn, "string", typeof(string)), new ResultColumn(valueColumn, "string", typeof(string))], rows);
    }

    private static void AppendPaths(List<object?[]> rows, BsonDocument document, string? prefix)
    {
        foreach (var element in document)
        {
            var path = prefix is null ? element.Name : string.Concat(prefix, ".", element.Name);
            if (element.Value is BsonDocument nested && nested.ElementCount > 0)
            {
                AppendPaths(rows, nested, path);
                continue;
            }

            rows.Add([path, ScalarText(element.Value)]);
        }
    }

    private static string? ScalarText(BsonValue value) => value.BsonType switch
    {
        BsonType.Null => null,
        BsonType.String => value.AsString,
        BsonType.Boolean => value.AsBoolean ? "true" : "false",
        BsonType.Int32 or BsonType.Int64 or BsonType.Double or BsonType.Decimal128 => value.ToString(),
        BsonType.DateTime when value.IsValidDateTime => value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss.fff", System.Globalization.CultureInfo.InvariantCulture),
        BsonType.ObjectId => value.AsObjectId.ToString(),
        _ => ExtendedJson.Write(value),
    };
}
