using TablePro.Core.Localization;

namespace TablePro.Core.Principals;

/// <summary>How deep in the server a grant reaches, from the whole server down to one column.</summary>
public enum PrivilegeLevel
{
    Server,
    Database,
    Schema,
    Table,
    Column,
}

/// <summary>
/// The object a privilege is granted on. One record for every level rather than a type per level, so two scopes
/// compare by value and serve as dictionary keys without a custom comparer.
/// </summary>
public sealed record PrivilegeScope
{
    private PrivilegeScope(PrivilegeLevel level, string? database, string? schema, string? table, string? column)
    {
        Level = level;
        Database = database;
        Schema = schema;
        Table = table;
        Column = column;
    }

    public static PrivilegeScope Server { get; } = new(PrivilegeLevel.Server, null, null, null, null);

    public PrivilegeLevel Level { get; }

    public string? Database { get; }

    public string? Schema { get; }

    public string? Table { get; }

    public string? Column { get; }

    public static PrivilegeScope ForDatabase(string database) => new(PrivilegeLevel.Database, database, null, null, null);

    public static PrivilegeScope ForSchema(string database, string schema) => new(PrivilegeLevel.Schema, database, schema, null, null);

    /// <summary>A table or view. <paramref name="schema"/> is null on engines whose databases hold tables directly.</summary>
    public static PrivilegeScope ForTable(string database, string? schema, string table) => new(PrivilegeLevel.Table, database, schema, table, null);

    public static PrivilegeScope ForColumn(string database, string? schema, string table, string column) =>
        new(PrivilegeLevel.Column, database, schema, table, column);

    public PrivilegeScope? Parent => Level switch
    {
        PrivilegeLevel.Database => Server,
        PrivilegeLevel.Schema => ForDatabase(Database!),
        PrivilegeLevel.Table => Schema is null ? ForDatabase(Database!) : ForSchema(Database!, Schema),
        PrivilegeLevel.Column => ForTable(Database!, Schema, Table!),
        _ => null,
    };

    /// <summary>The object a GRANT names: a column grant is written against its table with a column list.</summary>
    public PrivilegeScope GrantTarget => Level == PrivilegeLevel.Column ? Parent! : this;

    public string DisplayName => Level switch
    {
        PrivilegeLevel.Database => Database!,
        PrivilegeLevel.Schema => Schema!,
        PrivilegeLevel.Table => Table!,
        PrivilegeLevel.Column => Column!,
        _ => CoreStrings.Get("Principal/Server"),
    };

    /// <summary>Every name from the database down, for headers where the object alone would be ambiguous.</summary>
    public string DisplayPath => Level == PrivilegeLevel.Server ? CoreStrings.Get("Principal/Server") : string.Join(" › ", Parts());

    /// <summary>Orders parents before their children and siblings by name.</summary>
    public string SortKey => Level == PrivilegeLevel.Server ? string.Empty : string.Join('\u001F', Parts());

    /// <summary>Whether <paramref name="other"/> lies strictly below this scope.</summary>
    public bool Contains(PrivilegeScope other)
    {
        for (var candidate = other.Parent; candidate is not null; candidate = candidate.Parent)
        {
            if (candidate == this)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Whether a selection spans more than one level. Each level grants different privileges, so such a selection has
    /// no checklist to show.
    /// </summary>
    public static bool IsMixedLevel(IEnumerable<PrivilegeScope> scopes)
    {
        ArgumentNullException.ThrowIfNull(scopes);
        PrivilegeLevel? level = null;
        foreach (var scope in scopes)
        {
            if (level is { } first && first != scope.Level)
            {
                return true;
            }

            level = scope.Level;
        }

        return false;
    }

    public override string ToString() => DisplayPath;

    private IEnumerable<string> Parts()
    {
        if (Database is not null)
        {
            yield return Database;
        }

        if (Schema is not null)
        {
            yield return Schema;
        }

        if (Table is not null)
        {
            yield return Table;
        }

        if (Column is not null)
        {
            yield return Column;
        }
    }
}
