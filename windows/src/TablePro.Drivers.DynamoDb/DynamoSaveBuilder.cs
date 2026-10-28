using System.Globalization;
using Amazon.DynamoDBv2.Model;
using TablePro.Core.Editing;

namespace TablePro.Drivers.DynamoDb;

/// <summary>A table's key attributes with their declared types (S, N or B), hash key first.</summary>
public sealed record DynamoKeySchema(IReadOnlyList<KeyValuePair<string, string>> Keys)
{
    public IReadOnlyList<string> Names { get; } = [.. Keys.Select(k => k.Key)];

    public IReadOnlyDictionary<string, string> Types { get; } = Keys.ToDictionary(k => k.Key, k => k.Value, StringComparer.Ordinal);

    public string HashKey => Keys[0].Key;
}

/// <summary>
/// The TransactWriteItems a grid save sends. Each write is conditioned on the item's existence (or absence, for an
/// insert), so a change to an item someone else removed fails the whole transaction instead of creating it again.
/// </summary>
public static class DynamoSaveBuilder
{
    /// <summary>DynamoDB's limit on the actions of one transaction.</summary>
    public const int MaxTransactionItems = 100;

    public static List<TransactWriteItem> Build(
        string table,
        DynamoKeySchema keys,
        IReadOnlyList<RowChange> changes,
        IReadOnlyDictionary<string, string>? attributeTypes = null)
    {
        var items = new List<TransactWriteItem>(changes.Count);
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update when update.Values.Count > 0:
                    items.Add(new TransactWriteItem { Update = Update(table, keys, update, attributeTypes) });
                    break;
                case RowInsert insert:
                    items.Add(new TransactWriteItem { Put = Put(table, keys, insert, attributeTypes) });
                    break;
                case RowDelete delete:
                    items.Add(new TransactWriteItem { Delete = Delete(table, keys, delete) });
                    break;
            }
        }

        if (items.Count > MaxTransactionItems)
        {
            throw new InvalidOperationException(
                string.Create(CultureInfo.InvariantCulture, $"DynamoDB writes at most {MaxTransactionItems} items in one transaction, and this save has {items.Count}. Save fewer rows at once."));
        }

        return items;
    }

    public static Dictionary<string, AttributeValue> Key(DynamoKeySchema keys, IReadOnlyDictionary<string, object?> row)
    {
        var key = new Dictionary<string, AttributeValue>(StringComparer.Ordinal);
        foreach (var (name, type) in keys.Keys)
        {
            if (!row.TryGetValue(name, out var value) || value is null)
            {
                throw new InvalidOperationException($"The item's key attribute {name} is not loaded, so the item cannot be found.");
            }

            key[name] = DynamoAttributeMapper.KeyFromCell(value, type);
        }

        return key;
    }

    private static Update Update(string table, DynamoKeySchema keys, RowUpdate update, IReadOnlyDictionary<string, string>? types)
    {
        var names = new Dictionary<string, string>(StringComparer.Ordinal) { ["#k"] = keys.HashKey };
        var values = new Dictionary<string, AttributeValue>(StringComparer.Ordinal);
        var set = new List<string>();
        var remove = new List<string>();
        foreach (var (attribute, value) in update.Values)
        {
            if (keys.Types.ContainsKey(attribute))
            {
                throw new InvalidOperationException($"DynamoDB cannot change the key attribute {attribute}. Delete the item and add it again with the new key.");
            }

            var name = string.Create(CultureInfo.InvariantCulture, $"#a{names.Count - 1}");
            names[name] = attribute;

            // A cleared cell removes the attribute, which is how a schemaless item says it has no value.
            if (value is null)
            {
                remove.Add(name);
                continue;
            }

            var placeholder = string.Create(CultureInfo.InvariantCulture, $":v{values.Count}");
            values[placeholder] = DynamoAttributeMapper.FromCell(value, types?.GetValueOrDefault(attribute));
            set.Add($"{name} = {placeholder}");
        }

        var expression = set.Count > 0 ? "SET " + string.Join(", ", set) : string.Empty;
        if (remove.Count > 0)
        {
            expression += (expression.Length > 0 ? " " : string.Empty) + "REMOVE " + string.Join(", ", remove);
        }

        return new Update
        {
            TableName = table,
            Key = Key(keys, update.Key),
            UpdateExpression = expression,
            ConditionExpression = "attribute_exists(#k)",
            ExpressionAttributeNames = names,
            ExpressionAttributeValues = values.Count > 0 ? values : null,
        };
    }

    private static Put Put(string table, DynamoKeySchema keys, RowInsert insert, IReadOnlyDictionary<string, string>? types)
    {
        var item = Key(keys, insert.Values);
        foreach (var (attribute, value) in insert.Values)
        {
            // An item holds only the attributes it has; an empty cell is simply not written.
            if (value is not null && !keys.Types.ContainsKey(attribute))
            {
                item[attribute] = DynamoAttributeMapper.FromCell(value, types?.GetValueOrDefault(attribute));
            }
        }

        return new Put
        {
            TableName = table,
            Item = item,
            ConditionExpression = "attribute_not_exists(#k)",
            ExpressionAttributeNames = new Dictionary<string, string>(StringComparer.Ordinal) { ["#k"] = keys.HashKey },
        };
    }

    private static Delete Delete(string table, DynamoKeySchema keys, RowDelete delete) => new()
    {
        TableName = table,
        Key = Key(keys, delete.Key),
        ConditionExpression = "attribute_exists(#k)",
        ExpressionAttributeNames = new Dictionary<string, string>(StringComparer.Ordinal) { ["#k"] = keys.HashKey },
    };
}
