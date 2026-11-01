using Amazon.DynamoDBv2.Model;
using TablePro.Core.Results;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// Lays schemaless items out as a grid: the key attributes first, then every other attribute any item holds, by name.
/// A column's type text lists each DynamoDB type the attribute held, since items of one table may disagree.
/// </summary>
public static class DynamoItemTable
{
    public static ResultSet Build(IReadOnlyList<Dictionary<string, AttributeValue>> items, IReadOnlyList<string> keyNames, bool isTruncated = false)
    {
        var types = AttributeTypes(items);
        var names = new List<string>(keyNames.Count + types.Count);
        names.AddRange(keyNames);
        names.AddRange(types.Keys.Where(n => !keyNames.Contains(n)).Order(StringComparer.Ordinal));

        var columns = new ResultColumn[names.Count];
        for (var i = 0; i < names.Count; i++)
        {
            var seen = types.TryGetValue(names[i], out var set) ? set : [];
            columns[i] = new ResultColumn(names[i], seen.Count == 0 ? DynamoAttributeMapper.String : string.Join('|', seen), ClrTypeFor(seen));
        }

        var rows = new List<object?[]>(items.Count);
        foreach (var item in items)
        {
            var row = new object?[names.Count];
            for (var i = 0; i < names.Count; i++)
            {
                row[i] = item.TryGetValue(names[i], out var value) ? DynamoAttributeMapper.ToCell(value) : null;
            }

            rows.Add(row);
        }

        return new ResultSet(columns, rows, isTruncated);
    }

    /// <summary>Every type each attribute held across the items, in the order first seen.</summary>
    public static Dictionary<string, List<string>> AttributeTypes(IEnumerable<IReadOnlyDictionary<string, AttributeValue>> items)
    {
        var types = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            foreach (var (name, value) in item)
            {
                var type = DynamoAttributeMapper.TypeOf(value);
                if (!types.TryGetValue(name, out var list))
                {
                    types[name] = list = [];
                }

                if (type != DynamoAttributeMapper.Null && !list.Contains(type))
                {
                    list.Add(type);
                }
            }
        }

        return types;
    }

    private static Type ClrTypeFor(List<string> types) => types is [var only] ? only switch
    {
        DynamoAttributeMapper.Number => typeof(decimal),
        DynamoAttributeMapper.Boolean => typeof(bool),
        DynamoAttributeMapper.Binary => typeof(byte[]),
        _ => typeof(string),
    } : typeof(string);
}
