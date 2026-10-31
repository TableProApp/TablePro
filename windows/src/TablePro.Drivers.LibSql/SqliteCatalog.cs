using System.Globalization;
using System.Text.RegularExpressions;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.LibSql;

/// <summary>Runs one catalog statement with ordered parameters and returns its rows.</summary>
internal delegate Task<ResultSet> CatalogQuery(string sql, IReadOnlyList<object?> parameters, CancellationToken cancellationToken);

/// <summary>
/// libSQL is SQLite behind HTTP, so its catalog is read with the table-valued pragmas and <c>sqlite_master</c>.
/// Each statement runs on a stream of its own, so nothing here may rely on a pragma set by an earlier one.
/// </summary>
internal static partial class SqliteCatalog
{
    // libsql_ tables are the server's own (libsql_wasm_func_table) and _litestream_ belongs to its replication.
    public const string Objects = """
        SELECT name, type FROM sqlite_master
        WHERE type IN ('table', 'view') AND name NOT GLOB 'sqlite_*' AND name NOT GLOB 'libsql_*' AND name NOT GLOB '_litestream_*'
        ORDER BY name
        """;

    public const string Columns = """
        SELECT name, type, "notnull", dflt_value, pk FROM pragma_table_info(?1) ORDER BY cid
        """;

    public const string Indexes = """
        SELECT il.name, il."unique", il.origin, ii.name
        FROM pragma_index_list(?1) AS il
        JOIN pragma_index_info(il.name) AS ii
        ORDER BY il.origin = 'pk' DESC, il.name, ii.seqno
        """;

    // A key that names no parent columns points at the parent's primary key, which table_info gives by position.
    public const string ForeignKeys = """
        SELECT f.id, f."table", f."from",
               ifnull(f."to", (SELECT k.name FROM pragma_table_info(f."table") AS k WHERE k.pk = f.seq + 1)),
               f.on_update, f.on_delete
        FROM pragma_foreign_key_list(?1) AS f
        ORDER BY f.id, f.seq
        """;

    public const string Triggers = """
        SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 AND sql IS NOT NULL ORDER BY name
        """;

    public const string Definition = "SELECT sql FROM sqlite_master WHERE name = ?1 AND sql IS NOT NULL";

    public static IReadOnlyList<DatabaseObject> MapObjects(ResultSet rows)
    {
        var objects = new List<DatabaseObject>(rows.RowCount);
        foreach (var row in rows.Rows)
        {
            if (row[0] is string name)
            {
                var kind = string.Equals(row[1] as string, "view", StringComparison.OrdinalIgnoreCase) ? ObjectKind.View : ObjectKind.Table;
                objects.Add(new DatabaseObject(new ObjectName(null, name), kind));
            }
        }

        return objects;
    }

    public static async Task<TableStructure> ReadStructureAsync(CatalogQuery query, ObjectName table, CancellationToken cancellationToken)
    {
        object?[] args = [table.Name];
        var columnRows = await query(Columns, args, cancellationToken);
        var indexRows = await query(Indexes, args, cancellationToken);
        var foreignKeyRows = await query(ForeignKeys, args, cancellationToken);
        var triggerRows = await query(Triggers, args, cancellationToken);
        return new TableStructure(table, MapColumns(columnRows), MapIndexes(indexRows), MapForeignKeys(foreignKeyRows), MapTriggers(triggerRows));
    }

    public static IReadOnlyList<ColumnInfo> MapColumns(ResultSet rows)
    {
        var primaryKeyCount = rows.Rows.Count(r => Integer(r[4]) > 0);
        var columns = new List<ColumnInfo>(rows.RowCount);
        var ordinal = 0;
        foreach (var row in rows.Rows)
        {
            var type = row[1] as string ?? string.Empty;
            var isPrimaryKey = Integer(row[4]) > 0;

            // A lone INTEGER PRIMARY KEY is the rowid, which SQLite fills on insert.
            var isIdentity = isPrimaryKey && primaryKeyCount == 1 && type.Equals("INTEGER", StringComparison.OrdinalIgnoreCase);
            columns.Add(new ColumnInfo(
                row[0] as string ?? string.Empty,
                type,
                Integer(row[2]) == 0 && !isPrimaryKey,
                row[3] is null ? null : Convert.ToString(row[3], CultureInfo.InvariantCulture),
                isPrimaryKey,
                isIdentity,
                ordinal++));
        }

        return columns;
    }

    public static IReadOnlyList<IndexInfo> MapIndexes(ResultSet rows)
    {
        var indexes = new List<IndexInfo>();
        var order = new List<string>();
        var byName = new Dictionary<string, (bool Unique, bool Primary, List<string> Columns)>(StringComparer.Ordinal);
        foreach (var row in rows.Rows)
        {
            if (row[0] is not string name)
            {
                continue;
            }

            if (!byName.TryGetValue(name, out var entry))
            {
                entry = (Integer(row[1]) != 0, string.Equals(row[2] as string, "pk", StringComparison.Ordinal), []);
                byName[name] = entry;
                order.Add(name);
            }

            if (row[3] is string column)
            {
                entry.Columns.Add(column);
            }
        }

        foreach (var name in order)
        {
            var (unique, primary, columns) = byName[name];
            indexes.Add(new IndexInfo(name, columns, unique, primary));
        }

        return indexes;
    }

    public static IReadOnlyList<ForeignKeyInfo> MapForeignKeys(ResultSet rows)
    {
        var keys = new List<ForeignKeyInfo>();
        long? currentId = null;
        string parent = string.Empty;
        string? onUpdate = null;
        string? onDelete = null;
        var from = new List<string>();
        var to = new List<string>();
        foreach (var row in rows.Rows)
        {
            var id = Integer(row[0]);
            if (currentId != id && currentId is not null)
            {
                keys.Add(Build(currentId.Value, parent, from, to, onUpdate, onDelete));
                from = [];
                to = [];
            }

            currentId = id;
            parent = row[1] as string ?? string.Empty;
            onUpdate = row[4] as string;
            onDelete = row[5] as string;
            from.Add(row[2] as string ?? string.Empty);
            to.Add(row[3] as string ?? string.Empty);
        }

        if (currentId is not null)
        {
            keys.Add(Build(currentId.Value, parent, from, to, onUpdate, onDelete));
        }

        return keys;

        static ForeignKeyInfo Build(long id, string parent, List<string> from, List<string> to, string? onUpdate, string? onDelete) =>
            new(string.Create(CultureInfo.InvariantCulture, $"fk_{id}"), from, new ObjectName(null, parent), to, onUpdate, onDelete);
    }

    public static IReadOnlyList<TriggerInfo> MapTriggers(ResultSet rows)
    {
        var triggers = new List<TriggerInfo>(rows.RowCount);
        foreach (var row in rows.Rows)
        {
            var sql = row[1] as string ?? string.Empty;
            var match = TriggerShape().Match(sql);
            var timing = match.Success && match.Groups[1].Success ? match.Groups[1].Value.ToUpperInvariant() : "BEFORE";
            var verb = match.Success ? match.Groups[2].Value.ToUpperInvariant() : string.Empty;
            timing = string.Join(' ', timing.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            triggers.Add(new TriggerInfo(row[0] as string ?? string.Empty, timing, verb, sql));
        }

        return triggers;
    }

    private static long Integer(object? value) => value switch
    {
        long l => l,
        double d => (long)d,
        string s when long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) => parsed,
        bool b => b ? 1 : 0,
        _ => 0,
    };

    // SQLite's own default timing is BEFORE when a trigger names none.
    [GeneratedRegex(@"\bTRIGGER\b.*?\b(BEFORE|AFTER|INSTEAD\s+OF)?\s*\b(INSERT|UPDATE|DELETE)\b", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex TriggerShape();
}
