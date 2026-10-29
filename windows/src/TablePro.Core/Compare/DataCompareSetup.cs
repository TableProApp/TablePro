using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <summary>
/// Lines two tables' columns up by name and picks the key, before any row is read. Columns one side lacks are listed
/// rather than compared, since there is nothing to compare them with.
/// </summary>
public sealed record DataCompareSetup(
    DataCompareSpec? Spec,
    IReadOnlyList<string> SourceOnlyColumns,
    IReadOnlyList<string> TargetOnlyColumns,
    string? Problem)
{
    /// <param name="source">The source table's structure.</param>
    /// <param name="target">The target table's structure.</param>
    /// <param name="keyColumns">Source column names to match rows on; null uses the source's primary key.</param>
    /// <param name="excludedColumns">Source columns left out of the comparison, such as an <c>updated_at</c> that always differs.</param>
    public static DataCompareSetup Create(
        TableStructure source,
        TableStructure target,
        IReadOnlyList<string>? keyColumns = null,
        IReadOnlyCollection<string>? excludedColumns = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(target);

        var targetByName = new Dictionary<string, ColumnInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var column in target.Columns)
        {
            targetByName.TryAdd(column.Name, column);
        }

        var keys = keyColumns is { Count: > 0 } ? keyColumns : source.PrimaryKey;
        var keySet = new HashSet<string>(keys, StringComparer.OrdinalIgnoreCase);
        var excluded = new HashSet<string>(excludedColumns ?? [], StringComparer.OrdinalIgnoreCase);
        excluded.ExceptWith(keySet);

        var columns = new List<ComparedColumn>(source.Columns.Count);
        var sourceOnly = new List<string>();
        foreach (var column in source.Columns.OrderBy(c => c.Ordinal))
        {
            if (!targetByName.Remove(column.Name, out var match))
            {
                sourceOnly.Add(column.Name);
                continue;
            }

            if (!excluded.Contains(column.Name))
            {
                columns.Add(new ComparedColumn(column.Name, match.Name, keySet.Contains(column.Name), match.DataType, match.IsIdentity));
            }
        }

        var targetOnly = targetByName.Values.OrderBy(c => c.Ordinal).Select(c => c.Name).ToArray();
        if (keySet.Count == 0)
        {
            return new(null, sourceOnly, targetOnly, CoreStrings.Format("Compare/NoPrimaryKey", source.Table));
        }

        var missing = keys.Where(k => !columns.Any(c => c.IsKey && string.Equals(c.Source, k, StringComparison.OrdinalIgnoreCase))).ToArray();
        if (missing.Length > 0)
        {
            return new(null, sourceOnly, targetOnly, CoreStrings.Format("Compare/KeyColumnNotOnBoth", string.Join(", ", missing)));
        }

        // Keys first, in the order chosen, so rows sort and read as the key describes.
        var ordered = keys
            .Select(k => columns.First(c => c.IsKey && string.Equals(c.Source, k, StringComparison.OrdinalIgnoreCase)))
            .Concat(columns.Where(c => !c.IsKey))
            .ToArray();
        return new(new DataCompareSpec(source.Table, target.Table, ordered), sourceOnly, targetOnly, null);
    }
}
