using System.Text;
using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <summary>
/// What a structure comparison ignores. Every option defaults to ignoring metadata that drifts between environments by
/// design, as on macOS.
/// </summary>
public sealed record SchemaCompareOptions
{
    public static readonly SchemaCompareOptions Default = new();

    public bool IgnoreIdentifierCase { get; init; } = true;

    public bool CompareIndexes { get; init; } = true;

    public bool CompareForeignKeys { get; init; } = true;

    public bool CompareDefaults { get; init; } = true;

    public bool CompareComments { get; init; }

    /// <summary>Script DROP TABLE for tables only the target has. Off by default: it loses data.</summary>
    public bool DropExtraTables { get; init; }

    /// <summary>Script DROP COLUMN for columns only the target has. Off by default: it loses data.</summary>
    public bool DropExtraColumns { get; init; }

    /// <summary>Script DROP INDEX and DROP CONSTRAINT for indexes and foreign keys only the target has.</summary>
    public bool DropExtraIndexes { get; init; } = true;

    internal StringComparer NameComparer => IgnoreIdentifierCase ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    internal StringComparison NameComparison => IgnoreIdentifierCase ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}

public enum SchemaDiffKind : byte
{
    OnlyInSource,
    OnlyInTarget,
    Changed,
    Identical,
}

/// <summary>
/// One table's structural difference: the <see cref="SchemaChange"/> edits that turn the target into the source,
/// and what differs but has no edit to express it, such as a changed primary key.
/// </summary>
public sealed record TableSchemaDiff(
    SchemaDiffKind Kind,
    string Name,
    TableStructure? Source,
    TableStructure? Target,
    IReadOnlyList<SchemaChange> Changes,
    IReadOnlyList<string> Notes);

/// <summary>Compares two sets of <see cref="TableStructure"/>, matching tables and their members by name.</summary>
public static class SchemaDiffEngine
{
    private static readonly Dictionary<string, string> TypeAliases = new(StringComparer.Ordinal)
    {
        ["integer"] = "int",
        ["int4"] = "int",
        ["int8"] = "bigint",
        ["int2"] = "smallint",
        ["serial"] = "int",
        ["serial4"] = "int",
        ["bigserial"] = "bigint",
        ["serial8"] = "bigint",
        ["smallserial"] = "smallint",
        ["bool"] = "boolean",
        ["character varying"] = "varchar",
        ["character"] = "char",
        ["double precision"] = "double",
        ["float8"] = "double",
        ["float4"] = "real",
        ["numeric"] = "decimal",
        ["timestamp without time zone"] = "timestamp",
        ["timestamp with time zone"] = "timestamptz",
        ["time without time zone"] = "time",
        ["time with time zone"] = "timetz",
    };

    /// <param name="source">The structure to make the target match.</param>
    /// <param name="target">The structure as it stands.</param>
    /// <param name="options">What to ignore; null uses <see cref="SchemaCompareOptions.Default"/>.</param>
    public static IReadOnlyList<TableSchemaDiff> Compare(IEnumerable<TableStructure> source, IEnumerable<TableStructure> target, SchemaCompareOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(target);
        options ??= SchemaCompareOptions.Default;

        // Matched on the bare name: comparing schema "staging" against schema "prod" is the point.
        var targets = new Dictionary<string, TableStructure>(options.NameComparer);
        foreach (var table in target)
        {
            targets.TryAdd(table.Table.Name, table);
        }

        var diffs = new List<TableSchemaDiff>();
        foreach (var table in source)
        {
            if (targets.Remove(table.Table.Name, out var match))
            {
                diffs.Add(CompareTable(table, match, options));
            }
            else
            {
                diffs.Add(new TableSchemaDiff(SchemaDiffKind.OnlyInSource, table.Table.Name, table, null, [], []));
            }
        }

        diffs.AddRange(targets.Values.Select(t => new TableSchemaDiff(SchemaDiffKind.OnlyInTarget, t.Table.Name, null, t, [], [])));
        diffs.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
        return diffs;
    }

    /// <summary>A type as written, reduced to one spelling: lower case, single spaces, and the common aliases folded.</summary>
    public static string NormalizeType(string dataType)
    {
        ArgumentNullException.ThrowIfNull(dataType);
        var collapsed = Collapse(dataType).ToLowerInvariant();
        var paren = collapsed.IndexOf('(', StringComparison.Ordinal);
        var head = (paren < 0 ? collapsed : collapsed[..paren]).Trim();
        var tail = paren < 0 ? string.Empty : collapsed[paren..].Replace(" ", string.Empty, StringComparison.Ordinal);

        // A schema-qualified type ("public.geometry") reads the same as the bare one the other side resolved.
        var dot = head.LastIndexOf('.');
        if (dot >= 0)
        {
            head = head[(dot + 1)..].Trim('"');
        }

        return (TypeAliases.TryGetValue(head, out var alias) ? alias : head) + tail;
    }

    /// <summary>A default expression without the casts and parentheses engines wrap it in.</summary>
    public static string? NormalizeDefault(string? expression)
    {
        if (string.IsNullOrWhiteSpace(expression))
        {
            return null;
        }

        var text = Collapse(expression);
        while (text.Length >= 2 && text[0] == '(' && text[^1] == ')')
        {
            text = text[1..^1].Trim();
        }

        // PostgreSQL reports 'x'::character varying for a default written 'x'.
        var cast = text.LastIndexOf("::", StringComparison.Ordinal);
        if (cast > 0 && text.IndexOf('\'', cast) < 0)
        {
            text = text[..cast].Trim();
        }

        return string.Equals(text, "null", StringComparison.OrdinalIgnoreCase) ? null : text;
    }

    private static TableSchemaDiff CompareTable(TableStructure source, TableStructure target, SchemaCompareOptions options)
    {
        var changes = new List<SchemaChange>();
        var notes = new List<string>();
        CompareColumns(source, target, options, changes, notes);

        if (!source.PrimaryKey.SequenceEqual(target.PrimaryKey, options.NameComparer))
        {
            notes.Add(CoreStrings.Format("Compare/PrimaryKeyDiffers", string.Join(", ", source.PrimaryKey), string.Join(", ", target.PrimaryKey)));
        }

        if (options.CompareIndexes)
        {
            CompareIndexes(source, target, options, changes);
        }

        if (options.CompareForeignKeys)
        {
            CompareForeignKeys(source, target, options, changes);
        }

        var kind = changes.Count == 0 && notes.Count == 0 ? SchemaDiffKind.Identical : SchemaDiffKind.Changed;
        return new TableSchemaDiff(kind, source.Table.Name, source, target, changes, notes);
    }

    private static void CompareColumns(TableStructure source, TableStructure target, SchemaCompareOptions options, List<SchemaChange> changes, List<string> notes)
    {
        var targetColumns = new Dictionary<string, ColumnInfo>(options.NameComparer);
        foreach (var column in target.Columns)
        {
            targetColumns.TryAdd(column.Name, column);
        }

        foreach (var column in source.Columns.OrderBy(c => c.Ordinal))
        {
            if (!targetColumns.Remove(column.Name, out var match))
            {
                changes.Add(new AddColumn(ColumnDefinition.From(column) with { IsPrimaryKey = false }));
                continue;
            }

            if (!ColumnsMatch(column, match, options))
            {
                var after = ColumnDefinition.From(column) with { Name = match.Name, IsPrimaryKey = match.IsPrimaryKey };
                changes.Add(new AlterColumn(ColumnDefinition.From(match), after));
            }
        }

        foreach (var extra in targetColumns.Values.OrderBy(c => c.Ordinal))
        {
            if (options.DropExtraColumns)
            {
                changes.Add(new DropColumn(extra.Name));
            }
            else
            {
                notes.Add(CoreStrings.Format("Compare/ColumnOnlyInTarget", extra.Name));
            }
        }
    }

    private static bool ColumnsMatch(ColumnInfo source, ColumnInfo target, SchemaCompareOptions options) =>
        string.Equals(NormalizeType(source.DataType), NormalizeType(target.DataType), StringComparison.Ordinal)
        && source.IsNullable == target.IsNullable
        && (!options.CompareDefaults || source.IsIdentity || target.IsIdentity
            || string.Equals(NormalizeDefault(source.DefaultValue), NormalizeDefault(target.DefaultValue), StringComparison.OrdinalIgnoreCase))
        && (!options.CompareComments || string.Equals(source.Comment ?? string.Empty, target.Comment ?? string.Empty, StringComparison.Ordinal));

    private static void CompareIndexes(TableStructure source, TableStructure target, SchemaCompareOptions options, List<SchemaChange> changes)
    {
        var targetIndexes = new Dictionary<string, IndexInfo>(options.NameComparer);
        foreach (var index in target.Indexes.Where(i => !i.IsPrimary))
        {
            targetIndexes.TryAdd(index.Name, index);
        }

        foreach (var index in source.Indexes.Where(i => !i.IsPrimary))
        {
            var definition = new CreateIndex(new IndexDefinition(index.Name, index.Columns, index.IsUnique));
            if (!targetIndexes.Remove(index.Name, out var match))
            {
                changes.Add(definition);
            }
            else if (match.IsUnique != index.IsUnique || !match.Columns.SequenceEqual(index.Columns, options.NameComparer))
            {
                changes.Add(new DropIndex(match.Name));
                changes.Add(definition);
            }
        }

        if (options.DropExtraIndexes)
        {
            changes.AddRange(targetIndexes.Values.Select(i => new DropIndex(i.Name)));
        }
    }

    private static void CompareForeignKeys(TableStructure source, TableStructure target, SchemaCompareOptions options, List<SchemaChange> changes)
    {
        var targetKeys = new Dictionary<string, ForeignKeyInfo>(options.NameComparer);
        foreach (var key in target.ForeignKeys)
        {
            targetKeys.TryAdd(key.Name, key);
        }

        foreach (var key in source.ForeignKeys)
        {
            var add = new AddForeignKey(ForeignKeyFor(key, target.Table.Schema));
            if (!targetKeys.Remove(key.Name, out var match))
            {
                changes.Add(add);
            }
            else if (!ForeignKeysMatch(key, match, options))
            {
                changes.Add(new DropForeignKey(match.Name));
                changes.Add(add);
            }
        }

        if (options.DropExtraIndexes)
        {
            changes.AddRange(targetKeys.Values.Select(k => new DropForeignKey(k.Name)));
        }
    }

    /// <summary>The source's foreign key pointed at the same-named table in the target's schema.</summary>
    internal static ForeignKeyDefinition ForeignKeyFor(ForeignKeyInfo key, string? targetSchema) =>
        new(key.Name, key.Columns, key.ReferencedTable with { Schema = targetSchema }, key.ReferencedColumns, key.OnDelete, key.OnUpdate);

    private static bool ForeignKeysMatch(ForeignKeyInfo source, ForeignKeyInfo target, SchemaCompareOptions options) =>
        string.Equals(source.ReferencedTable.Name, target.ReferencedTable.Name, options.NameComparison)
        && source.Columns.SequenceEqual(target.Columns, options.NameComparer)
        && source.ReferencedColumns.SequenceEqual(target.ReferencedColumns, options.NameComparer)
        && string.Equals(Action(source.OnDelete), Action(target.OnDelete), StringComparison.OrdinalIgnoreCase)
        && string.Equals(Action(source.OnUpdate), Action(target.OnUpdate), StringComparison.OrdinalIgnoreCase);

    // Engines report the default referential action as NO ACTION, RESTRICT or nothing at all.
    private static string Action(string? action) =>
        string.IsNullOrWhiteSpace(action) || action.Equals("NO ACTION", StringComparison.OrdinalIgnoreCase) || action.Equals("RESTRICT", StringComparison.OrdinalIgnoreCase)
            ? string.Empty
            : Collapse(action);

    private static string Collapse(string text)
    {
        var sb = new StringBuilder(text.Length);
        var space = false;
        foreach (var c in text.AsSpan().Trim())
        {
            if (char.IsWhiteSpace(c))
            {
                space = true;
                continue;
            }

            if (space)
            {
                sb.Append(' ');
                space = false;
            }

            sb.Append(c);
        }

        return sb.ToString();
    }
}
