using TablePro.Core.Browse;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

public enum CompareMode
{
    Data,
    Structure,
}

/// <summary>Which tables a data comparison walks.</summary>
public enum DataCompareScope
{
    /// <summary>One source table against one target table, which may be named differently.</summary>
    OneTable,

    /// <summary>The tables the user ticked among those both sides share.</summary>
    ChosenTables,

    /// <summary>Every table both sides share, read again on each run so a table added later is included.</summary>
    WholeSchema,
}

/// <summary>
/// How one table is compared: the columns that identify a row, the columns left out, the rows read, as the macOS
/// app's <c>DataTableScope</c> keeps them per table.
/// </summary>
public sealed record CompareTableScope
{
    public static readonly CompareTableScope Default = new();

    /// <summary>Source columns to match rows on. Empty uses the source's primary key.</summary>
    public IReadOnlyList<string> KeyColumns { get; init; } = [];

    /// <summary>Source columns left out of the comparison, such as an <c>updated_at</c> that always differs.</summary>
    public IReadOnlyList<string> ExcludedColumns { get; init; } = [];

    /// <summary>A SQL condition applied to the source. Empty reads every row.</summary>
    public string? SourceFilter { get; init; }

    /// <summary>The target's condition. Null applies <see cref="SourceFilter"/> to the target too; empty reads every row.</summary>
    public string? TargetFilter { get; init; }

    /// <summary>Rows read from each side at most, in key order. Null reads the whole table.</summary>
    public long? RowLimit { get; init; }

    public bool UsesSameFilterForTarget => TargetFilter is null;

    public bool IsDefault =>
        KeyColumns is not { Count: > 0 } && ExcludedColumns is not { Count: > 0 }
        && string.IsNullOrWhiteSpace(SourceFilter) && string.IsNullOrWhiteSpace(TargetFilter) && RowLimit is null;

    public BrowseFilter SourceBrowseFilter => ToFilter(SourceFilter);

    public BrowseFilter TargetBrowseFilter => ToFilter(TargetFilter ?? SourceFilter);

    /// <summary>A copy whose lists are never null, for scopes read from a file written by hand or by an older build.</summary>
    public CompareTableScope Normalized() => this with
    {
        KeyColumns = KeyColumns ?? [],
        ExcludedColumns = ExcludedColumns ?? [],
        RowLimit = RowLimit is { } limit ? Math.Max(1, limit) : null,
    };

    private static BrowseFilter ToFilter(string? where) =>
        string.IsNullOrWhiteSpace(where) ? BrowseFilter.None : new BrowseFilter([], where.Trim());
}

/// <summary>A source table and the target table it is compared with.</summary>
public sealed record ComparedTablePair(ObjectName Source, ObjectName Target)
{
    /// <summary>The pair as a person reads it: one name when both sides spell it alike.</summary>
    public string DisplayName =>
        string.Equals(Source.Name, Target.Name, StringComparison.OrdinalIgnoreCase) ? Source.ToString() : $"{Source} → {Target}";
}

/// <summary>The tables two sides share, and those only one side has.</summary>
public sealed record TablePairing(
    IReadOnlyList<ComparedTablePair> Pairs,
    IReadOnlyList<ObjectName> SourceOnly,
    IReadOnlyList<ObjectName> TargetOnly)
{
    /// <summary>
    /// Pairs tables by name, ignoring case. A table first matches the target table with the same schema and name; one
    /// left over then matches by name alone when exactly one target table carries it, so <c>public.users</c> pairs with
    /// <c>dbo.users</c> across engines without guessing between two candidates.
    /// </summary>
    public static TablePairing Match(IEnumerable<ObjectName> source, IEnumerable<ObjectName> target)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(target);

        var sourceTables = source.Distinct().OrderBy(t => t.Name, StringComparer.OrdinalIgnoreCase).ThenBy(t => t.Schema, StringComparer.OrdinalIgnoreCase).ToList();
        var remaining = new List<ObjectName>(target.Distinct());
        var matched = new ObjectName?[sourceTables.Count];

        for (var i = 0; i < sourceTables.Count; i++)
        {
            var index = remaining.FindIndex(t => SameName(t, sourceTables[i]) && string.Equals(t.Schema ?? string.Empty, sourceTables[i].Schema ?? string.Empty, StringComparison.OrdinalIgnoreCase));
            if (index >= 0)
            {
                matched[i] = remaining[index];
                remaining.RemoveAt(index);
            }
        }

        for (var i = 0; i < sourceTables.Count; i++)
        {
            if (matched[i] is not null)
            {
                continue;
            }

            var candidates = remaining.FindAll(t => SameName(t, sourceTables[i]));
            var others = sourceTables.Count(s => SameName(s, sourceTables[i]));
            if (candidates.Count == 1 && others == 1)
            {
                matched[i] = candidates[0];
                remaining.Remove(candidates[0]);
            }
        }

        var pairs = new List<ComparedTablePair>(sourceTables.Count);
        var sourceOnly = new List<ObjectName>();
        for (var i = 0; i < sourceTables.Count; i++)
        {
            if (matched[i] is { } counterpart)
            {
                pairs.Add(new ComparedTablePair(sourceTables[i], counterpart));
            }
            else
            {
                sourceOnly.Add(sourceTables[i]);
            }
        }

        return new TablePairing(pairs, sourceOnly, [.. remaining.OrderBy(t => t.Name, StringComparer.OrdinalIgnoreCase)]);
    }

    private static bool SameName(ObjectName left, ObjectName right) => string.Equals(left.Name, right.Name, StringComparison.OrdinalIgnoreCase);
}
