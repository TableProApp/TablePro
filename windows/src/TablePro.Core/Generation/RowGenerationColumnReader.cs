using TablePro.Core.Connections;
using TablePro.Core.Copy;
using TablePro.Core.Schema;

namespace TablePro.Core.Generation;

/// <summary>What the loader has to sample: one referenced key per foreign key of the table.</summary>
public sealed record ReferenceRequest(string Id, IReadOnlyList<string> Columns, ObjectName ReferencedTable, IReadOnlyList<string> ReferencedColumns);

/// <summary>Turns a table's structure into what the generator needs to know about each column.</summary>
public static class RowGenerationColumnReader
{
    public static (IReadOnlyList<RowGenerationColumn> Columns, IReadOnlyList<IReadOnlyList<string>> UniqueGroups, IReadOnlyList<ReferenceRequest> References) Read(
        TableStructure structure, DatabaseEngine engine)
    {
        ArgumentNullException.ThrowIfNull(structure);
        var names = structure.Columns.Select(c => c.Name).ToHashSet(StringComparer.Ordinal);
        var primaryKey = structure.PrimaryKey;
        var keys = new List<IReadOnlyList<string>>();
        if (primaryKey.Count > 0)
        {
            keys.Add(primaryKey);
        }

        foreach (var index in structure.Indexes)
        {
            if ((index.IsUnique || index.IsPrimary) && index.Columns.Count > 0 && index.Columns.All(names.Contains))
            {
                keys.Add(index.Columns);
            }
        }

        var seenKeys = new HashSet<string>(StringComparer.Ordinal);
        keys = [.. keys.Where(k => seenKeys.Add(string.Join('\u001F', k.Order(StringComparer.Ordinal))))];
        var uniqueColumns = keys.Where(k => k.Count == 1).Select(k => k[0]).ToHashSet(StringComparer.Ordinal);

        var references = new List<ReferenceRequest>();
        var slots = new Dictionary<string, ReferenceSlot>(StringComparer.Ordinal);
        foreach (var key in structure.ForeignKeys)
        {
            if (key.Columns.Count == 0 || key.Columns.Count != key.ReferencedColumns.Count || !key.Columns.All(names.Contains))
            {
                continue;
            }

            var id = $"{key.Name}\u001F{key.ReferencedTable}";
            if (references.Any(r => r.Id == id))
            {
                continue;
            }

            references.Add(new ReferenceRequest(id, key.Columns, key.ReferencedTable, key.ReferencedColumns));
            for (var position = 0; position < key.Columns.Count; position++)
            {
                slots.TryAdd(key.Columns[position], new ReferenceSlot(id, position));
            }
        }

        var columns = structure.Columns.OrderBy(c => c.Ordinal).Select(info =>
        {
            var shape = SqlTypeShape.Parse(info.DataType, engine);
            var (minimum, maximum) = shape.IntegerRange;
            return new RowGenerationColumn(info.Name, info.DataType, ValueClass(shape))
            {
                IntegerMinimum = shape.Category == SqlTypeCategory.Integer ? minimum : long.MinValue,
                IntegerMaximum = shape.Category == SqlTypeCategory.Integer ? maximum : long.MaxValue,
                Precision = shape.Precision,
                Scale = shape.Scale,
                MaxLength = shape.Category == SqlTypeCategory.Text ? shape.Length : null,
                Labels = shape.Labels,
                IsNullable = info.IsNullable && !info.IsPrimaryKey,
                HasDefault = HasDefault(info.DefaultValue),
                Ownership = Ownership(info, shape, engine, primaryKey),
                IsUnique = uniqueColumns.Contains(info.Name),
                Reference = slots.TryGetValue(info.Name, out var slot) ? slot : null,
            };
        }).ToArray();

        return (columns, [.. keys.Where(k => k.Count > 1)], references);
    }

    public static RowValueClass ValueClass(SqlTypeShape shape)
    {
        ArgumentNullException.ThrowIfNull(shape);
        return shape.Category switch
        {
            SqlTypeCategory.Integer => RowValueClass.Integer,
            SqlTypeCategory.Decimal => RowValueClass.Decimal,
            SqlTypeCategory.Float => RowValueClass.FloatingPoint,
            SqlTypeCategory.Text => RowValueClass.Text,
            SqlTypeCategory.Boolean => RowValueClass.Boolean,
            SqlTypeCategory.Date => RowValueClass.Date,
            SqlTypeCategory.Time => RowValueClass.Time,
            SqlTypeCategory.Timestamp => RowValueClass.Timestamp,
            SqlTypeCategory.Uuid => RowValueClass.Uuid,
            SqlTypeCategory.Json => RowValueClass.Json,
            SqlTypeCategory.Enumeration when shape.Labels.Count > 0 => RowValueClass.Enumeration,
            _ => RowValueClass.Unsupported,
        };
    }

    private static bool HasDefault(string? value)
    {
        var trimmed = value?.Trim();
        return !string.IsNullOrEmpty(trimmed)
            && !trimmed.Equals("NULL", StringComparison.OrdinalIgnoreCase)
            && !trimmed.StartsWith("NULL::", StringComparison.OrdinalIgnoreCase);
    }

    private static ServerOwnership Ownership(ColumnInfo info, SqlTypeShape shape, DatabaseEngine engine, IReadOnlyList<string> primaryKey)
    {
        // SQL Server refuses a value for an identity column unless IDENTITY_INSERT is on, which a pooled save cannot hold.
        if (shape.Category == SqlTypeCategory.ServerComputed || (info.IsIdentity && engine == DatabaseEngine.SqlServer))
        {
            return ServerOwnership.Computed;
        }

        if (info.IsIdentity || (info.DefaultValue?.TrimStart().StartsWith("nextval(", StringComparison.OrdinalIgnoreCase) ?? false))
        {
            return ServerOwnership.Assigned;
        }

        // SQLite's INTEGER PRIMARY KEY is the rowid: left out, it takes the next one.
        return SqlTypeShape.IsSqlite(engine) && primaryKey.Count == 1 && primaryKey[0] == info.Name
            && string.Equals(info.DataType.Trim(), "INTEGER", StringComparison.OrdinalIgnoreCase)
            ? ServerOwnership.Assigned
            : ServerOwnership.None;
    }
}
