using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Oracle;

/// <summary>The Oracle statements for each structure change, and the catalog text helpers. Pure, so tests pin them.</summary>
internal static class OracleDdl
{
    // Core has no package or synonym kind; the session marks them with these comments so drops and definitions
    // find the right object type.
    public const string PackageMarker = "Package";
    public const string SynonymPrefix = "Synonym for ";

    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "NUMBER", "NUMBER(10)", "NUMBER(19)", "NUMBER(18,2)", "VARCHAR2(255 CHAR)", "VARCHAR2(4000 CHAR)", "NVARCHAR2(255)", "CHAR(1 CHAR)",
        "DATE", "TIMESTAMP(6)", "TIMESTAMP(6) WITH TIME ZONE", "CLOB", "NCLOB", "BLOB", "RAW(16)", "BINARY_DOUBLE", "BINARY_FLOAT",
        "FLOAT", "INTERVAL DAY(2) TO SECOND(6)", "BOOLEAN", "JSON",
    ];

    private static SqlDialect Dialect => OracleDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => CreateTable(create),
        AddColumn add => AddColumn(table, add.Column),
        DropColumn drop => [string.Concat(AlterTable(table), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [RenameColumn(table, rename.From, rename.To)],
        AlterColumn alter => AlterColumn(table, alter.Before, alter.After),
        CreateIndex index => [CreateIndex(table, index.Index)],
        DropIndex index => [string.Concat("DROP INDEX ", Dialect.Qualify(table with { Name = index.Index }))],
        AddForeignKey key => [string.Concat(AlterTable(table), " ADD ", ForeignKey(table, key.ForeignKey))],
        DropForeignKey key => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(key.Name))],

        // RENAME TO takes a bare name: the table stays in its schema.
        RenameTable rename => [string.Concat(AlterTable(table), " RENAME TO ", Q(rename.NewName))],
        DropObject drop => DropObject(drop.Object, drop.Cascade) is { } sql ? [sql] : [],
        TruncateTable truncate => [string.Concat("TRUNCATE TABLE ", Dialect.Qualify(table), truncate.Cascade ? " CASCADE" : string.Empty)],
        AddCheckConstraint add => add.Constraint.IsComplete ? [string.Concat(AlterTable(table), " ADD ", CheckClause(add.Constraint))] : [],
        DropCheckConstraint drop => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(drop.Name))],
        AlterCheckConstraint alter => AlterCheck(table, alter),
        AddPartition add => AddPartition(table, add.Partition) is { } sql ? [sql] : [],
        DropPartition drop => [PartitionStatement(table, "DROP", drop.Partition)],
        TruncatePartition truncate => [PartitionStatement(table, "TRUNCATE", truncate.Partition)],
        SetTableOptions options => SetOptions(table, options.Changes),
        _ => [],
    };

    public static readonly IReadOnlyList<TableOptionSpec> TableOptionSpecs =
    [
        new(TableOptionNames.Comment, TableOptionKind.Text),
        new(TableOptionNames.Tablespace, TableOptionKind.Text, Placeholder: "USERS"),
        new(TableOptionNames.PctFree, TableOptionKind.Number, Placeholder: "10"),
        new(TableOptionNames.Logging, TableOptionKind.Choice, ["YES", "NO"]),
        new(TableOptionNames.RowMovement, TableOptionKind.Choice, ["ENABLED", "DISABLED"]),
    ];

    public static string CheckClause(CheckConstraintDefinition check) =>
        string.Concat("CONSTRAINT ", Q(check.Name.Trim()), " CHECK (", check.Expression.Trim(), ")");

    /// <summary>A rename is one statement; Oracle cannot drop and add in one ALTER TABLE, so a new expression takes two.</summary>
    public static List<string> AlterCheck(ObjectName table, AlterCheckConstraint alter)
    {
        if (alter.IsRenameOnly)
        {
            return [string.Concat(AlterTable(table), " RENAME CONSTRAINT ", Q(alter.Before.Name), " TO ", Q(alter.After.Name.Trim()))];
        }

        return alter.After.IsComplete
            ? [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(alter.Before.Name)), string.Concat(AlterTable(table), " ADD ", CheckClause(alter.After))]
            : [];
    }

    /// <summary>The bound as the partition list prints it, such as <c>VALUES LESS THAN (2025)</c>; a HASH partition states none.</summary>
    public static string? AddPartition(ObjectName table, PartitionDefinition partition)
    {
        if (string.IsNullOrWhiteSpace(partition.Name))
        {
            return null;
        }

        var bound = partition.Bound.Trim();
        return string.Concat(AlterTable(table), " ADD PARTITION ", Q(partition.Name.Trim()), bound.Length == 0 ? string.Empty : " " + bound);
    }

    /// <summary>
    /// UPDATE GLOBAL INDEXES keeps the table's global indexes usable; without it Oracle marks them UNUSABLE and every
    /// query that would use one fails until it is rebuilt.
    /// </summary>
    public static string PartitionStatement(ObjectName table, string verb, PartitionInfo partition) =>
        string.Concat(AlterTable(table), " ", verb, partition.IsSubpartition ? " SUBPARTITION " : " PARTITION ", Q(partition.Name), " UPDATE GLOBAL INDEXES");

    public static List<string> SetOptions(ObjectName table, IReadOnlyList<TableOptionChange> changes)
    {
        var statements = new List<string>(changes.Count);
        foreach (var change in changes)
        {
            var value = change.After?.Trim();
            switch (change.Name)
            {
                case TableOptionNames.Comment:
                    statements.Add(string.Concat("COMMENT ON TABLE ", Dialect.Qualify(table), " IS ", Dialect.StringLiteral(value ?? string.Empty)));
                    break;

                // MOVE rewrites the segment and would leave every index UNUSABLE; UPDATE INDEXES (12.2) rebuilds them with it.
                case TableOptionNames.Tablespace when !string.IsNullOrEmpty(value):
                    statements.Add(string.Concat(AlterTable(table), " MOVE TABLESPACE ", DictionaryName(value), " UPDATE INDEXES"));
                    break;
                case TableOptionNames.PctFree:
                    statements.Add(int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var percent) && percent <= 99
                        ? string.Concat(AlterTable(table), " PCTFREE ", percent.ToString(CultureInfo.InvariantCulture))
                        : throw new ArgumentException("Percent free is a whole number from 0 to 99."));
                    break;
                case TableOptionNames.Logging:
                    statements.Add(string.Concat(AlterTable(table), value?.ToUpperInvariant() switch
                    {
                        "YES" or "LOGGING" => " LOGGING",
                        "NO" or "NOLOGGING" => " NOLOGGING",
                        _ => throw new ArgumentException("Logging is YES or NO."),
                    }));
                    break;
                case TableOptionNames.RowMovement:
                    statements.Add(string.Concat(AlterTable(table), value?.ToUpperInvariant() switch
                    {
                        "ENABLED" or "ENABLE" => " ENABLE ROW MOVEMENT",
                        "DISABLED" or "DISABLE" => " DISABLE ROW MOVEMENT",
                        _ => throw new ArgumentException("Row movement is ENABLED or DISABLED."),
                    }));
                    break;
            }
        }

        return statements;
    }

    public static List<TableOption> ReadOptions(string? tablespace, int? pctFree, string? logging, string? compression, string? rowMovement, string? comment) =>
    [
        new(TableOptionNames.Comment, string.IsNullOrEmpty(comment) ? null : comment),
        new(TableOptionNames.Tablespace, tablespace),
        new(TableOptionNames.PctFree, pctFree?.ToString(CultureInfo.InvariantCulture)),
        new(TableOptionNames.Logging, logging?.Trim()),
        new(TableOptionNames.RowMovement, rowMovement?.Trim()),
        new(TableOptionNames.Compression, compression?.Trim()),
    ];

    /// <summary>The NOT NULL of a column, which Oracle keeps as a check named by the system, written <c>"COL" IS NOT NULL</c>.</summary>
    public static bool IsNotNullCheck(string condition)
    {
        var text = condition.Trim();
        const string Suffix = " IS NOT NULL";
        if (!text.EndsWith(Suffix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var column = text[..^Suffix.Length].Trim();
        return column.Length > 2 && column[0] == '"' && column[^1] == '"' && column.IndexOf('"', 1) == column.Length - 1;
    }

    /// <summary>A RANGE bound is the upper limit and a LIST bound the values; HASH partitions state none.</summary>
    public static string? PartitionBound(string? method, string? highValue)
    {
        var value = highValue?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        return method?.Trim().ToUpperInvariant() switch
        {
            "RANGE" => $"VALUES LESS THAN ({value})",
            "LIST" => $"VALUES ({value})",
            _ => null,
        };
    }

    // A dictionary name such as a tablespace is stored in capitals; an unquoted name is folded the same way, so a plain
    // name the user typed in lower case still matches, and anything else is quoted.
    private static string DictionaryName(string name)
    {
        foreach (var c in name)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c is not '_' and not '$' and not '#')
            {
                return Q(name);
            }
        }

        return char.IsAsciiLetter(name[0]) ? name.ToUpperInvariant() : Q(name);
    }

    /// <summary>
    /// Auto-increment is <c>GENERATED BY DEFAULT ON NULL AS IDENTITY</c>, so an explicit key from an import still
    /// inserts (ALWAYS refuses it with ORA-32795). An identity takes no DEFAULT, and ON NULL already makes it NOT NULL.
    /// DEFAULT comes before NOT NULL, which is the order Oracle's grammar takes.
    /// </summary>
    public static string ColumnSql(ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(column.DataType.Trim());
        if (column.IsIdentity)
        {
            sql.Append(" GENERATED BY DEFAULT ON NULL AS IDENTITY");
        }
        else
        {
            if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
            {
                sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
            }

            if (!column.IsNullable && !inlinePrimaryKey)
            {
                sql.Append(" NOT NULL");
            }
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");
        }

        return sql.ToString();
    }

    public static List<string> CreateTable(CreateTable change)
    {
        var primaryKey = change.Columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToList();
        var sql = new StringBuilder("CREATE TABLE ").Append(Dialect.Qualify(change.Table)).Append(" (\n  ");
        for (var i = 0; i < change.Columns.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(",\n  ");
            }

            var column = change.Columns[i];
            sql.Append(ColumnSql(column, primaryKey.Count == 1 && column.IsPrimaryKey));
        }

        if (primaryKey.Count > 1)
        {
            sql.Append(",\n  CONSTRAINT ").Append(Q(Truncate("PK_" + change.Table.Name))).Append(" PRIMARY KEY (").Append(JoinQuoted(primaryKey)).Append(')');
        }

        var statements = new List<string> { sql.Append("\n)").ToString() };
        foreach (var column in change.Columns)
        {
            if (!string.IsNullOrEmpty(column.Comment))
            {
                statements.Add(ColumnComment(change.Table, column.Name, column.Comment));
            }
        }

        return statements;
    }

    public static List<string> AddColumn(ObjectName table, ColumnDefinition column)
    {
        var statements = new List<string>(2) { string.Concat(AlterTable(table), " ADD (", ColumnSql(column, column.IsPrimaryKey), ")") };
        if (!string.IsNullOrEmpty(column.Comment))
        {
            statements.Add(ColumnComment(table, column.Name, column.Comment));
        }

        return statements;
    }

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat(AlterTable(table), " RENAME COLUMN ", Q(from), " TO ", Q(to));

    /// <summary>
    /// MODIFY names only what changed: restating NOT NULL on a column that has it fails with ORA-01442, and a type
    /// restated without its length unit takes the session's NLS_LENGTH_SEMANTICS. No default is written as
    /// <c>DEFAULT NULL</c>, since Oracle has no way to remove one.
    /// </summary>
    public static List<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var statements = new List<string>(3);
        var typeChanged = !string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase);
        var nullChanged = before.IsNullable != after.IsNullable;
        var beforeDefault = string.IsNullOrWhiteSpace(before.DefaultExpression) ? null : before.DefaultExpression.Trim();
        var afterDefault = string.IsNullOrWhiteSpace(after.DefaultExpression) ? null : after.DefaultExpression.Trim();
        var defaultChanged = !string.Equals(beforeDefault, afterDefault, StringComparison.Ordinal);

        if (typeChanged || nullChanged || defaultChanged)
        {
            var sql = new StringBuilder(AlterTable(table)).Append(" MODIFY (").Append(Q(before.Name));
            if (typeChanged)
            {
                sql.Append(' ').Append(after.DataType.Trim());
            }

            if (defaultChanged)
            {
                sql.Append(" DEFAULT ").Append(afterDefault ?? "NULL");
            }

            if (nullChanged)
            {
                sql.Append(after.IsNullable ? " NULL" : " NOT NULL");
            }

            statements.Add(sql.Append(')').ToString());
        }

        if (!string.Equals(before.Comment ?? string.Empty, after.Comment ?? string.Empty, StringComparison.Ordinal))
        {
            statements.Add(ColumnComment(table, before.Name, after.Comment));
        }

        if (!string.Equals(before.Name, after.Name, StringComparison.Ordinal))
        {
            statements.Add(RenameColumn(table, before.Name, after.Name));
        }

        return statements;
    }

    /// <summary>An index lives in its table's schema unless named otherwise.</summary>
    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat(
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Dialect.Qualify(table with { Name = index.Name }), " ON ",
            Dialect.Qualify(table), " (", JoinQuoted(index.Columns), ")");

    /// <summary>Oracle has ON DELETE CASCADE and SET NULL but no ON UPDATE action, so an update action is dropped.</summary>
    public static string ForeignKey(ObjectName table, ForeignKeyDefinition key)
    {
        var referenced = key.ReferencedTable.Schema is null ? key.ReferencedTable with { Schema = table.Schema } : key.ReferencedTable;
        var sql = new StringBuilder();
        if (!string.IsNullOrEmpty(key.Name))
        {
            sql.Append("CONSTRAINT ").Append(Q(key.Name)).Append(' ');
        }

        sql.Append("FOREIGN KEY (").Append(JoinQuoted(key.Columns)).Append(") REFERENCES ").Append(Dialect.Qualify(referenced))
            .Append(" (").Append(JoinQuoted(key.ReferencedColumns)).Append(')');
        var onDelete = key.OnDelete?.Trim().ToUpperInvariant();
        if (onDelete is "CASCADE" or "SET NULL")
        {
            sql.Append(" ON DELETE ").Append(onDelete);
        }

        return sql.ToString();
    }

    public static string? DropObject(DatabaseObject obj, bool cascade)
    {
        var name = Dialect.Qualify(obj.Name);
        return obj.Kind switch
        {
            ObjectKind.Table => string.Concat("DROP TABLE ", name, cascade ? " CASCADE CONSTRAINTS" : string.Empty),
            ObjectKind.View when obj.Comment?.StartsWith(SynonymPrefix, StringComparison.Ordinal) == true => "DROP SYNONYM " + name,
            ObjectKind.View => string.Concat("DROP VIEW ", name, cascade ? " CASCADE CONSTRAINTS" : string.Empty),
            ObjectKind.MaterializedView => "DROP MATERIALIZED VIEW " + name,
            ObjectKind.Procedure when obj.Comment == PackageMarker => "DROP PACKAGE " + name,
            ObjectKind.Procedure => "DROP PROCEDURE " + name,
            ObjectKind.Function => "DROP FUNCTION " + name,
            ObjectKind.Sequence => "DROP SEQUENCE " + name,
            ObjectKind.Trigger => "DROP TRIGGER " + name,
            _ => null,
        };
    }

    /// <summary>Oracle removes a comment only when it is set to the empty string.</summary>
    public static string ColumnComment(ObjectName table, string column, string? comment) =>
        string.Concat("COMMENT ON COLUMN ", Dialect.Qualify(table), ".", Q(column), " IS ", Dialect.StringLiteral(comment ?? string.Empty));

    /// <summary>
    /// ALTER SYSTEM KILL SESSION takes the session as a literal, so the id is checked to be <c>sid,serial#</c> digits
    /// before it is written into the text.
    /// </summary>
    public static string Kill(object processId)
    {
        var id = (Convert.ToString(processId, CultureInfo.InvariantCulture) ?? string.Empty).Replace(" ", string.Empty, StringComparison.Ordinal);
        var comma = id.IndexOf(',', StringComparison.Ordinal);
        if (comma <= 0 || comma == id.Length - 1 || !IsDigits(id.AsSpan(0, comma)) || !IsDigits(id.AsSpan(comma + 1)))
        {
            throw new ArgumentException($"\"{processId}\" is not an Oracle session id of the form sid,serial#.", nameof(processId));
        }

        return string.Concat("ALTER SYSTEM KILL SESSION '", id, "' IMMEDIATE");
    }

    /// <summary>The type as a CREATE TABLE would spell it, from ALL_TAB_COLUMNS' parts.</summary>
    public static string FormatType(string dataType, int dataLength, int charLength, string? charUsed, int? precision, int? scale)
    {
        switch (dataType)
        {
            case "VARCHAR2" or "CHAR":
                return charUsed == "C"
                    ? string.Create(CultureInfo.InvariantCulture, $"{dataType}({charLength} CHAR)")
                    : string.Create(CultureInfo.InvariantCulture, $"{dataType}({dataLength} BYTE)");
            case "NVARCHAR2" or "NCHAR":
                return string.Create(CultureInfo.InvariantCulture, $"{dataType}({charLength})");
            case "RAW" or "UROWID":
                return string.Create(CultureInfo.InvariantCulture, $"{dataType}({dataLength})");
            case "NUMBER":
                if (precision is null)
                {
                    return scale is 0 ? "NUMBER(*,0)" : "NUMBER";
                }

                return scale is null or 0
                    ? string.Create(CultureInfo.InvariantCulture, $"NUMBER({precision})")
                    : string.Create(CultureInfo.InvariantCulture, $"NUMBER({precision},{scale})");
            case "FLOAT":
                return precision is null or 126 ? "FLOAT" : string.Create(CultureInfo.InvariantCulture, $"FLOAT({precision})");
            default:
                return dataType;
        }
    }

    /// <summary>BEFORE, AFTER or INSTEAD OF, from ALL_TRIGGERS.TRIGGER_TYPE such as <c>BEFORE EACH ROW</c>.</summary>
    public static string Timing(string triggerType)
    {
        var upper = triggerType.ToUpperInvariant();
        if (upper.Contains("INSTEAD OF", StringComparison.Ordinal))
        {
            return "INSTEAD OF";
        }

        return upper.StartsWith("BEFORE", StringComparison.Ordinal) ? "BEFORE" : "AFTER";
    }

    /// <summary>
    /// The statement that recreates a trigger. DESCRIPTION holds the header up to the body but neither the WHEN
    /// clause nor DISABLE, and a CALL trigger's body holds only the call's target with a <c>;</c> Oracle added.
    /// </summary>
    public static string TriggerDefinition(string name, string? description, string? whenClause, string? status, string? actionType, string? body)
    {
        var text = Trimmed(body);
        if (text is not null && string.Equals(Trimmed(actionType), "CALL", StringComparison.OrdinalIgnoreCase))
        {
            text = "CALL " + text.TrimEnd(';').TrimEnd();
        }

        if (Trimmed(description) is not { } header)
        {
            return text is null ? string.Empty : string.Concat("CREATE OR REPLACE TRIGGER ", Q(name), "\n", text);
        }

        var lines = new List<string>(4) { "CREATE OR REPLACE TRIGGER " + header };
        if (string.Equals(Trimmed(status), "DISABLED", StringComparison.OrdinalIgnoreCase))
        {
            lines.Add("DISABLE");
        }

        if (Trimmed(whenClause) is { } condition)
        {
            lines.Add(string.Concat("WHEN (", condition, ")"));
        }

        if (text is not null)
        {
            lines.Add(text);
        }

        return string.Join('\n', lines);
    }

    /// <summary>The DBMS_METADATA object type for a kind; views and procedures are resolved against the catalog first.</summary>
    public static string MetadataType(string objectType) => objectType.Replace(' ', '_');

    private static bool IsDigits(ReadOnlySpan<char> text)
    {
        foreach (var c in text)
        {
            if (!char.IsAsciiDigit(c))
            {
                return false;
            }
        }

        return true;
    }

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    // Before 12.2 a name is at most 30 bytes; keeping generated names short works on every version.
    private static string Truncate(string name) => name.Length <= 30 ? name : name[..30];

    private static string AlterTable(ObjectName table) => "ALTER TABLE " + Dialect.Qualify(table);

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string JoinQuoted(IReadOnlyList<string> names) => string.Join(", ", names.Select(Q));
}
