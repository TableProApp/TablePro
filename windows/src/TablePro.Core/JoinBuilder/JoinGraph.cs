using TablePro.Core.Schema;

namespace TablePro.Core.JoinBuilder;

/// <summary>One column of a foreign key: the child's column and the parent column it points at.</summary>
public readonly record struct JoinColumnPair(string Child, string Parent);

/// <summary>A foreign key between two tables of one schema, every column of a composite key in order.</summary>
public sealed class JoinRelationship(string name, string childTable, string parentTable, IReadOnlyList<JoinColumnPair> columnPairs)
    : IEquatable<JoinRelationship>
{
    public string Name { get; } = name;

    public string ChildTable { get; } = childTable;

    public string ParentTable { get; } = parentTable;

    public IReadOnlyList<JoinColumnPair> ColumnPairs { get; } = columnPairs;

    public string Id => string.Join('\u001F', ChildTable, Name, ParentTable);

    public bool Links(string table, string other) =>
        (ChildTable == table && ParentTable == other) || (ChildTable == other && ParentTable == table);

    public string? PartnerOf(string table) => ChildTable == table ? ParentTable : ParentTable == table ? ChildTable : null;

    /// <summary>What a join picker shows: <c>orders.customer_id = customers.id</c>, each pair joined with AND.</summary>
    public string Title => string.Join(" AND ", ColumnPairs.Select(p => $"{ChildTable}.{p.Child} = {ParentTable}.{p.Parent}"));

    public bool Equals(JoinRelationship? other) =>
        other is not null
        && Name == other.Name
        && ChildTable == other.ChildTable
        && ParentTable == other.ParentTable
        && ColumnPairs.SequenceEqual(other.ColumnPairs);

    public override bool Equals(object? obj) => Equals(obj as JoinRelationship);

    public override int GetHashCode() => HashCode.Combine(Name, ChildTable, ParentTable, ColumnPairs.Count);

    public override string ToString() => Title;
}

/// <summary>One table a path adds, and the key that joins it to a table already in the query.</summary>
public readonly record struct JoinStep(string Table, JoinRelationship Relationship);

/// <summary>
/// The tables of one schema with their columns and the foreign keys between them, which is everything the join
/// builder suggests joins from. Table names are the catalog's own spelling.
/// </summary>
public sealed class JoinGraph
{
    private readonly Dictionary<string, IReadOnlyList<string>> _columns;
    private readonly Dictionary<string, Dictionary<string, string>> _types;

    // A key from a table to itself is left out: it joins nothing between two tables.
    private readonly Dictionary<string, List<JoinRelationship>> _relationshipsByTable = new(StringComparer.Ordinal);

    public JoinGraph(
        IReadOnlyDictionary<string, IReadOnlyList<string>> columnsByTable,
        IReadOnlyList<JoinRelationship> relationships,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>>? columnTypes = null)
    {
        ArgumentNullException.ThrowIfNull(columnsByTable);
        ArgumentNullException.ThrowIfNull(relationships);
        _columns = new Dictionary<string, IReadOnlyList<string>>(columnsByTable, StringComparer.Ordinal);
        _types = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        if (columnTypes is not null)
        {
            foreach (var (table, types) in columnTypes)
            {
                _types[table] = new Dictionary<string, string>(types, StringComparer.Ordinal);
            }
        }

        Relationships = relationships;
        foreach (var relationship in relationships)
        {
            if (relationship.ChildTable == relationship.ParentTable)
            {
                continue;
            }

            Add(relationship.ChildTable, relationship);
            Add(relationship.ParentTable, relationship);
        }

        // Linguistic order puts order_items before orders, as a person reading the list expects.
        TableNames = [.. _columns.Keys.Order(StringComparer.InvariantCultureIgnoreCase)];
    }

    public static JoinGraph Empty { get; } = new(new Dictionary<string, IReadOnlyList<string>>(), []);

    public IReadOnlyList<JoinRelationship> Relationships { get; }

    /// <summary>Every table, sorted as the sidebar sorts them.</summary>
    public IReadOnlyList<string> TableNames { get; }

    public bool IsEmpty => _columns.Count == 0;

    /// <summary>
    /// Builds the graph from table structures. A key into another schema is dropped, since it would otherwise join a
    /// same-named table of this one; a key spelled in another case than the catalog, as SQLite reports one, follows
    /// the catalog's spelling, and an exact spelling wins over one that differs only in case.
    /// </summary>
    public static JoinGraph FromStructures(IEnumerable<TableStructure> structures, string? schema)
    {
        ArgumentNullException.ThrowIfNull(structures);
        var list = structures as IReadOnlyCollection<TableStructure> ?? [.. structures];
        var columns = new Dictionary<string, IReadOnlyList<string>>(list.Count, StringComparer.Ordinal);
        var types = new Dictionary<string, IReadOnlyDictionary<string, string>>(list.Count, StringComparer.Ordinal);
        foreach (var structure in list)
        {
            var name = structure.Table.Name;
            if (columns.ContainsKey(name))
            {
                continue;
            }

            columns[name] = [.. structure.Columns.OrderBy(c => c.Ordinal).Select(c => c.Name)];
            var byName = new Dictionary<string, string>(structure.Columns.Count, StringComparer.Ordinal);
            foreach (var column in structure.Columns)
            {
                byName.TryAdd(column.Name, column.DataType);
            }

            types[name] = byName;
        }

        var relationships = new List<JoinRelationship>();
        foreach (var structure in list.OrderBy(s => s.Table.Name, StringComparer.Ordinal))
        {
            var child = structure.Table.Name;
            if (!columns.TryGetValue(child, out var childColumns))
            {
                continue;
            }

            foreach (var key in structure.ForeignKeys)
            {
                if (!IsLocal(key.ReferencedTable.Schema, schema)
                    || Canonical(columns.Keys, key.ReferencedTable.Name) is not { } parent
                    || key.Columns.Count == 0
                    || key.Columns.Count != key.ReferencedColumns.Count)
                {
                    continue;
                }

                var parentColumns = columns[parent];
                var pairs = new List<JoinColumnPair>(key.Columns.Count);
                for (var i = 0; i < key.Columns.Count; i++)
                {
                    var pair = new JoinColumnPair(
                        Canonical(childColumns, key.Columns[i]) ?? key.Columns[i],
                        Canonical(parentColumns, key.ReferencedColumns[i]) ?? key.ReferencedColumns[i]);
                    if (!pairs.Contains(pair))
                    {
                        pairs.Add(pair);
                    }
                }

                relationships.Add(new JoinRelationship(key.Name, child, parent, pairs));
            }
        }

        return new JoinGraph(columns, relationships, types);
    }

    private static bool IsLocal(string? referencedSchema, string? schema) =>
        string.IsNullOrEmpty(referencedSchema) || string.IsNullOrEmpty(schema) || string.Equals(referencedSchema, schema, StringComparison.OrdinalIgnoreCase);

    private static string? Canonical(IEnumerable<string> names, string name)
    {
        string? folded = null;
        var foldedCount = 0;
        foreach (var candidate in names)
        {
            if (string.Equals(candidate, name, StringComparison.Ordinal))
            {
                return candidate;
            }

            if (string.Equals(candidate, name, StringComparison.OrdinalIgnoreCase))
            {
                folded = candidate;
                foldedCount++;
            }
        }

        // Two catalog names that differ only in case leave a folded reference ambiguous, so it links neither.
        return foldedCount == 1 ? folded : null;
    }

    public bool Contains(string table) => _columns.ContainsKey(table);

    public IReadOnlyList<string> ColumnsOf(string table) => _columns.TryGetValue(table, out var columns) ? columns : [];

    /// <summary>The column's declared type, or null when the catalog did not say.</summary>
    public string? TypeOf(string table, string column) =>
        _types.TryGetValue(table, out var types) && types.TryGetValue(column, out var type) ? type : null;

    public IReadOnlyList<JoinRelationship> RelationshipsBetween(string table, string other) =>
        _relationshipsByTable.TryGetValue(table, out var list) ? [.. list.Where(r => r.PartnerOf(table) == other)] : [];

    /// <summary>
    /// The cheapest chain of foreign keys from any table already joined to <paramref name="table"/>: empty when it is
    /// joined already, null when no key reaches it. Two tables that only share a parent multiply each other's rows,
    /// so that hop costs extra and a junction table or a chain of the same length wins.
    /// </summary>
    public IReadOnlyList<JoinStep>? PathTo(string table, IReadOnlyList<string> joined)
    {
        ArgumentNullException.ThrowIfNull(joined);
        if (joined.Contains(table))
        {
            return [];
        }

        if (!_columns.ContainsKey(table))
        {
            return null;
        }

        var joinedTables = joined.ToHashSet(StringComparer.Ordinal);
        var bestCost = new Dictionary<(string Table, bool AsParent), int>();
        var cameFrom = new Dictionary<(string Table, bool AsParent), ((string Table, bool AsParent) Previous, JoinStep Step)>();

        // The order breaks ties, so of two equally cheap paths the one found first, from the earlier table, wins.
        var frontier = new PriorityQueue<(string Table, bool AsParent), (int Cost, int Order)>();
        var order = 0;
        foreach (var start in joined)
        {
            var state = (start, false);
            if (bestCost.TryAdd(state, 0))
            {
                frontier.Enqueue(state, (0, order++));
            }
        }

        while (frontier.TryDequeue(out var state, out var priority))
        {
            if (bestCost[state] != priority.Cost)
            {
                continue;
            }

            if (state.Table == table)
            {
                var steps = new List<JoinStep>();
                var current = state;
                while (cameFrom.TryGetValue(current, out var link))
                {
                    steps.Add(link.Step);
                    current = link.Previous;
                }

                steps.Reverse();
                return steps;
            }

            if (!_relationshipsByTable.TryGetValue(state.Table, out var relationships))
            {
                continue;
            }

            foreach (var relationship in relationships)
            {
                if (relationship.PartnerOf(state.Table) is not { } next || joinedTables.Contains(next))
                {
                    continue;
                }

                var leavesForChild = relationship.ParentTable == state.Table;
                var cost = priority.Cost + 2 + (state.AsParent && leavesForChild ? 1 : 0);
                var nextState = (next, relationship.ParentTable == next);
                if (bestCost.TryGetValue(nextState, out var known) && known <= cost)
                {
                    continue;
                }

                bestCost[nextState] = cost;
                cameFrom[nextState] = (state, new JoinStep(next, relationship));
                frontier.Enqueue(nextState, (cost, order++));
            }
        }

        return null;
    }

    private void Add(string table, JoinRelationship relationship)
    {
        if (!_relationshipsByTable.TryGetValue(table, out var list))
        {
            list = [];
            _relationshipsByTable[table] = list;
        }

        list.Add(relationship);
    }
}
