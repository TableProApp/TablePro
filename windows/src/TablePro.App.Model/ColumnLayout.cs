using System.Text.Json.Serialization;

namespace TablePro.App.Model;

// The grid's columns for one set of names: the data column at each display position, and how many from the left
// are frozen.
public sealed record ArrangedColumns(IReadOnlyList<int> Order, int Frozen)
{
    public static ArrangedColumns Identity(int count) => new([.. Enumerable.Range(0, Math.Max(0, count))], 0);

    public bool IsIdentity(int count) =>
        Frozen == 0 && Order.Count == count && Order.Select((column, index) => column == index).All(same => same);
}

// A table's columns as the user arranged them, by name, so a column added since goes last and a dropped one is passed
// over. Order lists hidden columns too, so one shown again comes back where it was.
public sealed record ColumnLayout
{
    public static ColumnLayout Default { get; } = new();

    public IReadOnlyList<string> Order { get; init; } = [];

    public IReadOnlyList<string> Hidden { get; init; } = [];

    // Shown columns from the left that stay in view as the rest scroll.
    public int Frozen { get; init; }

    [JsonIgnore]
    public bool IsDefault => Order.Count == 0 && Hidden.Count == 0 && Frozen == 0;

    // At least one column always shows, so a layout that would hide them all shows the first.
    public ArrangedColumns Resolve(IReadOnlyList<string> columns)
    {
        ArgumentNullException.ThrowIfNull(columns);
        var shown = Sequence(columns).Where(index => !IsHidden(columns[index])).ToList();
        if (shown.Count == 0 && columns.Count > 0)
        {
            shown.Add(0);
        }

        return new ArrangedColumns(shown, Math.Clamp(Frozen, 0, shown.Count));
    }

    public bool IsHidden(string column) => Hidden.Contains(column, StringComparer.Ordinal);

    // The last shown column stays.
    public ColumnLayout Hide(IReadOnlyList<string> columns, int dataColumn)
    {
        ArgumentNullException.ThrowIfNull(columns);
        var arranged = Resolve(columns);
        var position = IndexOf(arranged.Order, dataColumn);
        if (position < 0 || arranged.Order.Count <= 1)
        {
            return this;
        }

        return this with
        {
            Order = Names(columns),
            Hidden = [.. Hidden.Append(columns[dataColumn]).Distinct(StringComparer.Ordinal)],
            Frozen = position < arranged.Frozen ? arranged.Frozen - 1 : arranged.Frozen,
        };
    }

    public ColumnLayout Show(IReadOnlyList<string> columns, int dataColumn)
    {
        ArgumentNullException.ThrowIfNull(columns);
        var name = columns[dataColumn];
        return IsHidden(name)
            ? this with { Order = Names(columns), Hidden = [.. Hidden.Where(hidden => !string.Equals(hidden, name, StringComparison.Ordinal))] }
            : this;
    }

    public ColumnLayout ShowAll() => this with { Hidden = [] };

    // From and to are display positions among the shown columns; to is where the column ends up.
    public ColumnLayout Move(IReadOnlyList<string> columns, int from, int to)
    {
        ArgumentNullException.ThrowIfNull(columns);
        var shown = Resolve(columns).Order;
        if (from < 0 || from >= shown.Count || to < 0 || to >= shown.Count || from == to)
        {
            return this;
        }

        var full = Sequence(columns).ToList();
        var moving = shown[from];
        var reordered = shown.ToList();
        reordered.RemoveAt(from);
        reordered.Insert(to, moving);
        full.Remove(moving);
        // Placed before the shown column it lands in front of, or after the last shown one; hidden ones keep their places.
        var anchor = to + 1 < reordered.Count ? full.IndexOf(reordered[to + 1]) : full.IndexOf(reordered[to - 1]) + 1;
        full.Insert(anchor, moving);
        return this with { Order = [.. full.Select(index => columns[index])] };
    }

    public ColumnLayout Freeze(int count) => this with { Frozen = Math.Max(0, count) };

    private IEnumerable<int> Sequence(IReadOnlyList<string> columns)
    {
        var byName = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < columns.Count; index++)
        {
            byName.TryAdd(columns[index], index);
        }

        var placed = new HashSet<int>();
        foreach (var name in Order)
        {
            if (byName.TryGetValue(name, out var index) && placed.Add(index))
            {
                yield return index;
            }
        }

        for (var index = 0; index < columns.Count; index++)
        {
            if (placed.Add(index))
            {
                yield return index;
            }
        }
    }

    private List<string> Names(IReadOnlyList<string> columns) => [.. Sequence(columns).Select(index => columns[index])];

    private static int IndexOf(IReadOnlyList<int> order, int column)
    {
        for (var index = 0; index < order.Count; index++)
        {
            if (order[index] == column)
            {
                return index;
            }
        }

        return -1;
    }
}
