using TablePro.Core.Browse;
using TablePro.Core.Connections;

namespace TablePro.Core.JoinBuilder;

public enum JoinKind
{
    Inner,
    Left,
    Right,
    Full,
}

public static class JoinKinds
{
    public static string Keyword(this JoinKind kind) => kind switch
    {
        JoinKind.Left => "LEFT JOIN",
        JoinKind.Right => "RIGHT JOIN",
        JoinKind.Full => "FULL JOIN",
        _ => "JOIN",
    };

    public static string DisplayName(this JoinKind kind) => kind switch
    {
        JoinKind.Left => "Left Join",
        JoinKind.Right => "Right Join",
        JoinKind.Full => "Full Join",
        _ => "Inner Join",
    };

    /// <summary>The join types an engine runs. MySQL and its relatives have no FULL JOIN.</summary>
    public static IReadOnlyList<JoinKind> SupportedBy(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.MySql or DatabaseEngine.MariaDb or DatabaseEngine.TiDb or DatabaseEngine.OceanBase => [JoinKind.Inner, JoinKind.Left, JoinKind.Right],
        _ => [JoinKind.Inner, JoinKind.Left, JoinKind.Right, JoinKind.Full],
    };
}

public readonly record struct JoinColumnRef(string Table, string Column)
{
    public override string ToString() => $"{Table}.{Column}";
}

/// <summary>One WHERE condition of the join query, with the filter strip's operators.</summary>
public sealed class JoinFilter(JoinColumnRef column, FilterOperator op = FilterOperator.Equals, string value = "", string secondValue = "")
{
    public Guid Id { get; } = Guid.NewGuid();

    public JoinColumnRef Column { get; set; } = column;

    public FilterOperator Operator { get; set; } = op;

    public string Value { get; set; } = value;

    public string SecondValue { get; set; } = secondValue;
}

public sealed class JoinSort(JoinColumnRef column, bool descending = false)
{
    public Guid Id { get; } = Guid.NewGuid();

    public JoinColumnRef Column { get; set; } = column;

    public bool Descending { get; set; } = descending;
}

/// <summary>One table of the query. The first has no condition; a later one without a condition is cross joined.</summary>
public sealed class JoinTable(string name, JoinRelationship? condition = null)
{
    private readonly List<string> _selected = [];

    public string Name { get; } = name;

    public JoinKind Kind { get; internal set; } = JoinKind.Inner;

    public JoinRelationship? Condition { get; internal set; } = condition;

    /// <summary>The chosen columns, always in the table's own order; empty selects them all through the star.</summary>
    public IReadOnlyList<string> SelectedColumns => _selected;

    internal void SetSelected(IEnumerable<string> columns)
    {
        _selected.Clear();
        _selected.AddRange(columns);
    }
}

/// <summary>
/// What the join builder has picked: tables in FROM order with their join conditions, the chosen columns, filters and
/// sort. A table is added with the foreign keys that reach it from the tables already picked, bringing in a junction
/// table when that is the shortest way.
/// </summary>
public sealed class JoinQueryDraft
{
    private readonly List<JoinTable> _tables = [];

    public IReadOnlyList<JoinTable> Tables => _tables;

    public List<JoinFilter> Filters { get; } = [];

    public List<JoinSort> Sorts { get; } = [];

    public bool IsEmpty => _tables.Count == 0;

    public bool Contains(string table) => IndexOf(table) >= 0;

    public int IndexOf(string table) => _tables.FindIndex(t => t.Name == table);

    /// <summary>The tables after the first that no key links to an earlier one, so the query cross joins them.</summary>
    public IEnumerable<string> CrossJoinedTables => _tables.Skip(1).Where(t => t.Condition is null).Select(t => t.Name);

    public void Add(string table, JoinGraph graph)
    {
        ArgumentNullException.ThrowIfNull(graph);
        if (Contains(table) || !graph.Contains(table))
        {
            return;
        }

        if (_tables.Count == 0 || graph.PathTo(table, [.. _tables.Select(t => t.Name)]) is not { Count: > 0 } steps)
        {
            _tables.Add(new JoinTable(table));
            return;
        }

        foreach (var step in steps)
        {
            if (!Contains(step.Table))
            {
                _tables.Add(new JoinTable(step.Table, step.Relationship));
            }
        }
    }

    public void Remove(string table, JoinGraph graph)
    {
        ArgumentNullException.ThrowIfNull(graph);
        var index = IndexOf(table);
        if (index < 0)
        {
            return;
        }

        _tables.RemoveAt(index);
        Filters.RemoveAll(f => f.Column.Table == table);
        Sorts.RemoveAll(s => s.Column.Table == table);
        RelinkAfterRemoving(table, graph);
    }

    /// <summary>The keys a table can join on: a join condition can name only tables already in the FROM clause.</summary>
    public IReadOnlyList<JoinRelationship> Candidates(int index, JoinGraph graph)
    {
        ArgumentNullException.ThrowIfNull(graph);
        if (index <= 0 || index >= _tables.Count)
        {
            return [];
        }

        var table = _tables[index].Name;
        return [.. _tables.Take(index).SelectMany(earlier => graph.RelationshipsBetween(table, earlier.Name))];
    }

    public void SetKind(int index, JoinKind kind)
    {
        if (index >= 0 && index < _tables.Count)
        {
            _tables[index].Kind = kind;
        }
    }

    /// <summary>Sets a table's join key, or cross joins it with null. A key that does not reach an earlier table is ignored.</summary>
    public void SetCondition(int index, JoinRelationship? condition, JoinGraph graph)
    {
        if (index <= 0 || index >= _tables.Count)
        {
            return;
        }

        if (condition is null || Candidates(index, graph).Contains(condition))
        {
            _tables[index].Condition = condition;
        }
    }

    public bool IsSelected(JoinColumnRef column) =>
        _tables.Find(t => t.Name == column.Table)?.SelectedColumns.Contains(column.Column) == true;

    public void SetSelected(JoinColumnRef column, bool selected, JoinGraph graph)
    {
        ArgumentNullException.ThrowIfNull(graph);
        var table = _tables.Find(t => t.Name == column.Table);
        if (table is null)
        {
            return;
        }

        var chosen = table.SelectedColumns.ToHashSet(StringComparer.Ordinal);
        if (selected)
        {
            chosen.Add(column.Column);
        }
        else
        {
            chosen.Remove(column.Column);
        }

        table.SetSelected(graph.ColumnsOf(column.Table).Where(chosen.Contains));
    }

    /// <summary>Every column of every picked table, in FROM order, for the filter and sort pickers.</summary>
    public IEnumerable<JoinColumnRef> AvailableColumns(JoinGraph graph)
    {
        ArgumentNullException.ThrowIfNull(graph);
        return _tables.SelectMany(t => graph.ColumnsOf(t.Name).Select(c => new JoinColumnRef(t.Name, c)));
    }

    // Only a join that named the removed table changes; a cross join the user chose stays one.
    private void RelinkAfterRemoving(string removed, JoinGraph graph)
    {
        for (var i = 0; i < _tables.Count; i++)
        {
            if (i == 0)
            {
                _tables[i].Condition = null;
                continue;
            }

            if (_tables[i].Condition is { } condition && condition.PartnerOf(_tables[i].Name) == removed)
            {
                var candidates = Candidates(i, graph);
                _tables[i].Condition = candidates.Count > 0 ? candidates[0] : null;
            }
        }
    }
}
