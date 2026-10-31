using MongoDB.Bson;
using TablePro.Core.Results;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>The grid's view of a field: a native type when its values share one, JSON otherwise.</summary>
internal enum FieldKind
{
    Int,
    Long,
    Double,
    Decimal,
    String,
    Bool,
    Date,
    ObjectId,
    Json,
}

/// <summary>A top-level field shown as a column. <see cref="DataType"/> is the BSON type name the field's values share.</summary>
internal sealed record FieldColumn(string Name, FieldKind Kind, string DataType)
{
    public bool IsJson => Kind == FieldKind.Json;

    // An ObjectId shows as its hex digits and a JSON cell as text; neither type would mean anything outside the driver.
    public Type ClrType => Kind switch
    {
        FieldKind.Int => typeof(int),
        FieldKind.Long => typeof(long),
        FieldKind.Double => typeof(double),
        FieldKind.Decimal => typeof(decimal),
        FieldKind.Bool => typeof(bool),
        FieldKind.Date => typeof(DateTime),
        _ => typeof(string),
    };

    public ResultColumn ToResultColumn() => new(Name, DataType, ClrType);
}

/// <summary>
/// Which BSON types each top-level field holds and where it first appears, read either from documents or from the
/// tally the server makes with <c>$objectToArray</c>. Fields are ordered <c>_id</c> first, then by where documents
/// place them.
/// </summary>
internal sealed class FieldCensus
{
    public const int SampleSize = 1000;

    private static readonly string[] NumberTypes = ["int", "long", "double", "decimal"];

    private readonly Dictionary<string, (long Position, HashSet<string> Types)> _fields = new(StringComparer.Ordinal);

    public int FieldCount => _fields.Count;

    /// <summary>The fields of the first <paramref name="limit"/> documents, in the order they are first seen.</summary>
    public static FieldCensus FromDocuments(IEnumerable<BsonDocument> documents, int limit = SampleSize)
    {
        var census = new FieldCensus();
        long seen = 0;
        foreach (var document in documents.Take(limit))
        {
            foreach (var element in document)
            {
                census.Add(element.Name, TypeName(element.Value), seen++);
            }
        }

        return census;
    }

    /// <summary>
    /// Reads the server's tally, one document per field and type: <c>{_id: {name, type}, position}</c>, as the
    /// pipeline in <see cref="TallyPipeline"/> groups it.
    /// </summary>
    public static FieldCensus FromTallies(IEnumerable<BsonDocument> tallies)
    {
        var census = new FieldCensus();
        foreach (var tally in tallies)
        {
            if (!tally.TryGetValue("_id", out var key) || key is not BsonDocument id
                || !id.TryGetValue("name", out var name) || !name.IsString
                || !id.TryGetValue("type", out var type) || !type.IsString)
            {
                continue;
            }

            var position = tally.TryGetValue("position", out var p) && p.IsNumeric ? p.ToInt64() : long.MaxValue;
            census.Add(name.AsString, type.AsString, position);
        }

        return census;
    }

    /// <summary>
    /// Tallies the fields of the first documents in natural order on the server, so no document crosses the wire to
    /// describe a collection.
    /// </summary>
    public static BsonDocument[] TallyPipeline(int sample = SampleSize) =>
    [
        new("$limit", sample),
        new("$project", new BsonDocument { { "_id", 0 }, { "field", new BsonDocument("$objectToArray", "$$ROOT") } }),
        new("$unwind", new BsonDocument { { "path", "$field" }, { "includeArrayIndex", "position" } }),
        new("$group", new BsonDocument
        {
            { "_id", new BsonDocument { { "name", "$field.k" }, { "type", new BsonDocument("$type", "$field.v") } } },
            { "position", new BsonDocument("$min", "$position") },
        }),
    ];

    public void Add(string name, string typeName, long position)
    {
        if (_fields.TryGetValue(name, out var entry))
        {
            entry.Types.Add(typeName);
            if (position < entry.Position)
            {
                _fields[name] = (position, entry.Types);
            }
        }
        else
        {
            _fields[name] = (position, [typeName]);
        }
    }

    /// <summary>The columns, <c>_id</c> first. <paramref name="ensureId"/> adds an ObjectId <c>_id</c> to a collection none was seen in.</summary>
    public IReadOnlyList<FieldColumn> Columns(bool ensureId)
    {
        var ordered = _fields
            .OrderBy(f => f.Key == "_id" ? 0 : 1)
            .ThenBy(f => f.Value.Position)
            .ThenBy(f => f.Key, StringComparer.Ordinal)
            .Select(f => Column(f.Key, f.Value.Types))
            .ToList();
        if (ensureId && !_fields.ContainsKey("_id"))
        {
            ordered.Insert(0, new FieldColumn("_id", FieldKind.ObjectId, "objectId"));
        }

        return ordered;
    }

    public static FieldColumn Column(string name, IReadOnlyCollection<string> types)
    {
        var (kind, dataType) = SharedType(types);
        return new FieldColumn(name, kind, dataType);
    }

    /// <summary>
    /// The type a field's values share. Numbers of different widths share the widest; a null fits any type; documents,
    /// arrays, binary data and fields of several kinds are JSON, which writes each value as the type it is.
    /// </summary>
    public static (FieldKind Kind, string DataType) SharedType(IReadOnlyCollection<string> types)
    {
        var typed = types.Where(t => t != "null").ToHashSet(StringComparer.Ordinal);
        if (typed.Count > 0 && typed.All(t => NumberTypes.Contains(t, StringComparer.Ordinal)))
        {
            return typed.Contains("decimal") ? (FieldKind.Decimal, "decimal")
                : typed.Contains("double") ? (FieldKind.Double, "double")
                : typed.Contains("long") ? (FieldKind.Long, "long")
                : (FieldKind.Int, "int");
        }

        if (typed.Count != 1)
        {
            return (FieldKind.Json, "mixed");
        }

        var only = typed.First();
        return only switch
        {
            "string" => (FieldKind.String, "string"),
            "bool" => (FieldKind.Bool, "bool"),
            "date" => (FieldKind.Date, "date"),
            "objectId" => (FieldKind.ObjectId, "objectId"),
            _ => (FieldKind.Json, only),
        };
    }

    /// <summary>The name <c>$type</c> gives a value's type.</summary>
    public static string TypeName(BsonValue value) => value.BsonType switch
    {
        BsonType.Double => "double",
        BsonType.String => "string",
        BsonType.Document => "object",
        BsonType.Array => "array",
        BsonType.Binary => "binData",
        BsonType.Undefined => "undefined",
        BsonType.ObjectId => "objectId",
        BsonType.Boolean => "bool",
        BsonType.DateTime => "date",
        BsonType.Null => "null",
        BsonType.RegularExpression => "regex",
        BsonType.JavaScript => "javascript",
        BsonType.Symbol => "symbol",
        BsonType.JavaScriptWithScope => "javascriptWithScope",
        BsonType.Int32 => "int",
        BsonType.Timestamp => "timestamp",
        BsonType.Int64 => "long",
        BsonType.Decimal128 => "decimal",
        BsonType.MinKey => "minKey",
        BsonType.MaxKey => "maxKey",
        _ => "dbPointer",
    };
}
