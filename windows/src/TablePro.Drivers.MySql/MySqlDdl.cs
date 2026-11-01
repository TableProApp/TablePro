using System.Globalization;
using System.Text;
using TablePro.Core.Localization;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.MySql;

/// <summary>One row of information_schema.PARTITIONS.</summary>
internal sealed record MySqlPartitionRow(
    string Partition,
    string? Subpartition,
    string? Method,
    string? Expression,
    string? Description,
    int? Ordinal,
    int? SubpartitionOrdinal,
    long? Rows,
    long? SizeBytes,
    string? SubpartitionMethod = null,
    string? SubpartitionExpression = null);

/// <summary>
/// Which server a session talks to, for the statements whose spelling or support changed between releases. A version
/// that cannot be read leaves <see cref="Version"/> null, and then nothing version-gated is offered.
/// </summary>
internal sealed record MySqlServer(bool IsMariaDb, Version? Version)
{
    public static MySqlServer Current { get; } = new(false, new Version(8, 4, 0));

    /// <summary>
    /// Reads the leading version. An old MariaDB announces itself as <c>5.5.5-10.4.32-MariaDB</c> to clients that
    /// expect MySQL, so that prefix is skipped.
    /// </summary>
    public static MySqlServer Parse(string? serverVersion, bool isMariaDb)
    {
        var text = serverVersion ?? string.Empty;
        isMariaDb |= text.Contains("MariaDB", StringComparison.OrdinalIgnoreCase);
        if (isMariaDb && text.StartsWith("5.5.5-", StringComparison.Ordinal))
        {
            text = text[6..];
        }

        var end = 0;
        while (end < text.Length && (char.IsAsciiDigit(text[end]) || text[end] == '.'))
        {
            end++;
        }

        var parts = text[..end].Split('.', StringSplitOptions.RemoveEmptyEntries);
        Version? version = null;
        if (parts.Length >= 2
            && int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var major)
            && int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var minor))
        {
            var patch = parts.Length > 2 && int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var p) ? p : 0;
            version = new Version(major, minor, patch);
        }

        return new MySqlServer(isMariaDb, version);
    }

    /// <summary>
    /// Whether a CHECK written to this server survives and can be read back. MySQL before 8.0.16 and MariaDB before
    /// 10.2.1 parse the clause and discard it. MariaDB enforced checks from 10.2.1 but listed them in
    /// CHECK_CONSTRAINTS only from 10.2.22 and 10.3.10.
    /// </summary>
    public bool HasCheckConstraints => Version is { } v && (IsMariaDb
        ? v >= new Version(10, 4) || (v.Major == 10 && v.Minor == 3 && v.Build >= 10) || (v.Major == 10 && v.Minor == 2 && v.Build >= 22)
        : v >= new Version(8, 0, 16));

    public bool UsesDropCheck => !IsMariaDb && Version is { } v && v < new Version(8, 0, 19);
}

/// <summary>The MySQL and MariaDB statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class MySqlDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "INT", "BIGINT", "VARCHAR(255)", "TEXT", "DATETIME", "TIMESTAMP", "DATE", "DECIMAL(12,2)", "TINYINT(1)", "JSON",
        "INT UNSIGNED", "BIGINT UNSIGNED", "SMALLINT", "DOUBLE", "FLOAT", "CHAR(36)", "LONGTEXT", "BLOB", "TIME", "ENUM('a','b')",
    ];

    private static SqlDialect Dialect => MySqlDialect.Instance;

    /// <summary>The statements for one change. <paramref name="server"/> is the connected server; null means current MySQL.</summary>
    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change, MySqlServer? server = null) => change switch
    {
        AddCheckConstraint add => add.Constraint.IsComplete ? [AddCheck(table, add.Constraint)] : [],
        DropCheckConstraint drop => [DropCheck(table, drop.Name, server ?? MySqlServer.Current)],

        // MySQL has no RENAME CONSTRAINT, so even a rename drops the check and adds it again.
        AlterCheckConstraint alter => alter.After.IsComplete
            ? [DropCheck(table, alter.Before.Name, server ?? MySqlServer.Current), AddCheck(table, alter.After)]
            : [],
        AddPartition add => [AddPartition(table, add.Partition)],

        // A subpartition is reached only through its partition, which is what DROP and TRUNCATE name.
        DropPartition drop => drop.Partition.IsSubpartition ? [] : [string.Concat(AlterTable(table), " DROP PARTITION ", Q(drop.Partition.Name))],
        TruncatePartition truncate => truncate.Partition.IsSubpartition ? [] : [string.Concat(AlterTable(table), " TRUNCATE PARTITION ", Q(truncate.Partition.Name))],
        SetTableOptions options => SetOptions(table, options.Changes) is { } sql ? [sql] : [],
        _ => BuildTableChange(table, change),
    };

    private static IReadOnlyList<string> BuildTableChange(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => [CreateTable(create)],
        AddColumn add => [string.Concat(AlterTable(table), " ADD COLUMN ", ColumnSql(add.Column, add.Column.IsPrimaryKey))],
        DropColumn drop => [string.Concat(AlterTable(table), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [string.Concat(AlterTable(table), " RENAME COLUMN ", Q(rename.From), " TO ", Q(rename.To))],
        AlterColumn alter => [AlterColumn(table, alter.Before, alter.After)],
        CreateIndex index => [CreateIndex(table, index.Index)],
        DropIndex index => [DropIndex(table, index.Index)],
        AddForeignKey key => [string.Concat(AlterTable(table), " ADD ", ForeignKey(key.ForeignKey))],
        DropForeignKey key => [string.Concat(AlterTable(table), " DROP FOREIGN KEY ", Q(key.Name))],
        RenameTable rename => [string.Concat("RENAME TABLE ", Dialect.Qualify(table), " TO ", Dialect.Qualify(table with { Name = rename.NewName }))],
        DropObject drop => DropObject(drop.Object) is { } sql ? [sql] : [],
        TruncateTable => ["TRUNCATE TABLE " + Dialect.Qualify(table)],
        _ => [],
    };

    /// <summary>Clauses in the order the server's grammar lists them, which is also how SHOW CREATE TABLE writes them.</summary>
    public static string ColumnSql(ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(column.DataType.Trim());
        sql.Append(column.IsNullable && !inlinePrimaryKey ? " NULL" : " NOT NULL");
        if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        if (column.IsIdentity)
        {
            sql.Append(" AUTO_INCREMENT");
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");
        }

        if (!string.IsNullOrEmpty(column.Comment))
        {
            sql.Append(" COMMENT ").Append(Dialect.StringLiteral(column.Comment));
        }

        return sql.ToString();
    }

    public static string CreateTable(CreateTable change)
    {
        var primaryKey = new List<string>();
        foreach (var column in change.Columns)
        {
            if (column.IsPrimaryKey)
            {
                primaryKey.Add(column.Name);
            }
        }

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
            sql.Append(",\n  PRIMARY KEY (").Append(JoinQuoted(primaryKey)).Append(')');
        }

        return sql.Append("\n)").ToString();
    }

    /// <summary>
    /// MySQL restates the whole column to change any part of it; CHANGE also renames. The key stays where it is,
    /// since restating PRIMARY KEY on a keyed table fails with a duplicate key.
    /// </summary>
    public static string AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var definition = ColumnSql(after, inlinePrimaryKey: false);
        return string.Equals(before.Name, after.Name, StringComparison.Ordinal)
            ? string.Concat(AlterTable(table), " MODIFY COLUMN ", definition)
            : string.Concat(AlterTable(table), " CHANGE COLUMN ", Q(before.Name), " ", definition);
    }

    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat(
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Q(index.Name), " ON ", Dialect.Qualify(table),
            " (", JoinQuoted(index.Columns), ")");

    public static string DropIndex(ObjectName table, string index) =>
        string.Equals(index, "PRIMARY", StringComparison.OrdinalIgnoreCase)
            ? AlterTable(table) + " DROP PRIMARY KEY"
            : string.Concat("DROP INDEX ", Q(index), " ON ", Dialect.Qualify(table));

    public static string ForeignKey(ForeignKeyDefinition key)
    {
        var sql = new StringBuilder();
        if (!string.IsNullOrEmpty(key.Name))
        {
            sql.Append("CONSTRAINT ").Append(Q(key.Name)).Append(' ');
        }

        sql.Append("FOREIGN KEY (").Append(JoinQuoted(key.Columns)).Append(") REFERENCES ").Append(Dialect.Qualify(key.ReferencedTable))
            .Append(" (").Append(JoinQuoted(key.ReferencedColumns)).Append(')');
        if (!string.IsNullOrWhiteSpace(key.OnDelete))
        {
            sql.Append(" ON DELETE ").Append(key.OnDelete.Trim().ToUpperInvariant());
        }

        if (!string.IsNullOrWhiteSpace(key.OnUpdate))
        {
            sql.Append(" ON UPDATE ").Append(key.OnUpdate.Trim().ToUpperInvariant());
        }

        return sql.ToString();
    }

    public static string? DropObject(DatabaseObject obj)
    {
        var keyword = obj.Kind switch
        {
            ObjectKind.Table => "TABLE",
            ObjectKind.View => "VIEW",
            ObjectKind.Function => "FUNCTION",
            ObjectKind.Procedure => "PROCEDURE",
            ObjectKind.Trigger => "TRIGGER",
            ObjectKind.Sequence => "SEQUENCE",
            _ => null,
        };

        return keyword is null ? null : string.Concat("DROP ", keyword, " ", Dialect.Qualify(obj.Name));
    }

    /// <summary>The SHOW CREATE statement for an object and the column its text comes back in.</summary>
    public static (string Sql, int Ordinal)? ShowCreate(DatabaseObject obj)
    {
        var target = Dialect.Qualify(obj.Name);
        return obj.Kind switch
        {
            ObjectKind.Table => ("SHOW CREATE TABLE " + target, 1),
            ObjectKind.View => ("SHOW CREATE VIEW " + target, 1),
            ObjectKind.Procedure => ("SHOW CREATE PROCEDURE " + target, 2),
            ObjectKind.Function => ("SHOW CREATE FUNCTION " + target, 2),
            ObjectKind.Trigger => ("SHOW CREATE TRIGGER " + target, 2),
            ObjectKind.Sequence => ("SHOW CREATE SEQUENCE " + target, 1),
            _ => null,
        };
    }

    public static string Kill(object processId) =>
        "KILL CONNECTION " + Convert.ToUInt64(processId, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);

    public static readonly IReadOnlyList<TableOptionSpec> TableOptionSpecs =
    [
        new(TableOptionNames.Engine, TableOptionKind.Choice, ["InnoDB", "MyISAM", "Aria", "MEMORY", "ARCHIVE", "CSV", "BLACKHOLE", "ROCKSDB"]),
        new(TableOptionNames.Charset, TableOptionKind.Choice, ["utf8mb4", "utf8mb3", "latin1", "ascii", "binary", "utf16", "utf32", "cp1251", "big5", "gbk", "sjis"]),
        new(TableOptionNames.Collation, TableOptionKind.Choice,
        [
            "utf8mb4_0900_ai_ci", "utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_bin", "utf8mb4_unicode_520_ci", "utf8mb4_uca1400_ai_ci",
            "utf8mb3_general_ci", "utf8mb3_unicode_ci", "latin1_swedish_ci", "latin1_general_ci", "latin1_bin", "ascii_general_ci", "binary",
        ]),
        new(TableOptionNames.RowFormat, TableOptionKind.Choice, ["DEFAULT", "DYNAMIC", "COMPACT", "COMPRESSED", "REDUNDANT", "FIXED", "PAGE"]),
        new(TableOptionNames.AutoIncrement, TableOptionKind.Number, Placeholder: "1"),
        new(TableOptionNames.Comment, TableOptionKind.Text),
    ];

    public static string CheckClause(CheckConstraintDefinition check) =>
        string.Concat("CONSTRAINT ", Q(check.Name.Trim()), " CHECK (", check.Expression.Trim(), ")");

    public static string AddCheck(ObjectName table, CheckConstraintDefinition check) => string.Concat(AlterTable(table), " ADD ", CheckClause(check));

    /// <summary>MySQL 8.0.16 to 8.0.18 takes only DROP CHECK; 8.0.19 also takes DROP CONSTRAINT, the only form MariaDB knows.</summary>
    public static string DropCheck(ObjectName table, string name, MySqlServer server) =>
        string.Concat(AlterTable(table), server.UsesDropCheck ? " DROP CHECK " : " DROP CONSTRAINT ", Q(name));

    /// <summary>
    /// The bound is the one the partition list prints, such as <c>VALUES LESS THAN (2025)</c>. A HASH or KEY table has
    /// no bound to state, so an empty one asks the server for one more partition, which it names itself.
    /// </summary>
    public static string AddPartition(ObjectName table, PartitionDefinition partition)
    {
        var bound = partition.Bound.Trim();
        return bound.Length == 0 || string.IsNullOrWhiteSpace(partition.Name)
            ? string.Concat(AlterTable(table), " ADD PARTITION PARTITIONS 1")
            : string.Concat(AlterTable(table), " ADD PARTITION (PARTITION ", Q(partition.Name.Trim()), " ", bound, ")");
    }

    /// <summary>Every changed option goes in one ALTER TABLE, in the order SHOW CREATE TABLE writes them.</summary>
    public static string? SetOptions(ObjectName table, IReadOnlyList<TableOptionChange> changes)
    {
        var clauses = new List<string>(changes.Count);
        foreach (var name in (ReadOnlySpan<string>)[
            TableOptionNames.Engine, TableOptionNames.Charset, TableOptionNames.Collation, TableOptionNames.RowFormat,
            TableOptionNames.AutoIncrement, TableOptionNames.Comment])
        {
            var change = changes.FirstOrDefault(c => c.Name == name);
            if (change is null)
            {
                continue;
            }

            clauses.Add(name switch
            {
                TableOptionNames.Engine => "ENGINE = " + Word(change, name),
                TableOptionNames.Charset => "DEFAULT CHARSET = " + Word(change, name),
                TableOptionNames.Collation => "COLLATE = " + Word(change, name),
                TableOptionNames.RowFormat => "ROW_FORMAT = " + (change.Clears ? "DEFAULT" : Word(change, name).ToUpperInvariant()),
                TableOptionNames.AutoIncrement => "AUTO_INCREMENT = " + PositiveNumber(change, name),
                _ => "COMMENT = " + Dialect.StringLiteral(change.After?.Trim() ?? string.Empty),
            });
        }

        return clauses.Count == 0 ? null : string.Concat(AlterTable(table), " ", string.Join(", ", clauses));
    }

    /// <summary>The options of one information_schema.TABLES row. The character set is the collation's prefix, which is how MySQL names collations.</summary>
    public static List<TableOption> ReadOptions(string? engine, string? collation, string? rowFormat, ulong? autoIncrement, string? comment)
    {
        var charset = collation is null ? null : collation.IndexOf('_', StringComparison.Ordinal) is var underscore and > 0 ? collation[..underscore] : collation;
        return
        [
            new(TableOptionNames.Engine, engine),
            new(TableOptionNames.Charset, charset),
            new(TableOptionNames.Collation, collation),
            new(TableOptionNames.RowFormat, rowFormat),
            new(TableOptionNames.AutoIncrement, autoIncrement?.ToString(CultureInfo.InvariantCulture)),
            new(TableOptionNames.Comment, string.IsNullOrEmpty(comment) ? null : comment),
        ];
    }

    /// <summary>
    /// Folds information_schema.PARTITIONS into partitions followed by their subpartitions. The server gives the bound
    /// without its syntax (a bare <c>2024</c> for RANGE, <c>1,2,3</c> for LIST), so the syntax is put back.
    /// </summary>
    public static PartitioningInfo? Partitioning(IReadOnlyList<MySqlPartitionRow> rows)
    {
        if (rows.Count == 0)
        {
            return null;
        }

        var partitions = new List<PartitionInfo>(rows.Count);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in rows)
        {
            var hasSubpartition = row.Subpartition is not null;
            if (seen.Add(row.Partition))
            {
                partitions.Add(new PartitionInfo(row.Partition, Bound(row.Method, row.Description))
                {
                    Ordinal = row.Ordinal,
                    RowEstimate = hasSubpartition ? null : row.Rows,
                    SizeBytes = hasSubpartition ? null : row.SizeBytes,
                    IsSubpartitioned = hasSubpartition,
                });
            }

            if (hasSubpartition)
            {
                partitions.Add(new PartitionInfo(row.Subpartition!)
                {
                    Parent = row.Partition,
                    Ordinal = row.SubpartitionOrdinal,
                    RowEstimate = row.Rows,
                    SizeBytes = row.SizeBytes,
                });
            }
        }

        var first = rows[0];
        return new PartitioningInfo(first.Method ?? string.Empty, first.Expression?.Trim() ?? string.Empty, partitions)
        {
            Subpartitioning = first.SubpartitionMethod is null ? null : $"{first.SubpartitionMethod} ({first.SubpartitionExpression?.Trim()})",
        };
    }

    /// <summary>Matched by prefix, since RANGE COLUMNS and LIST COLUMNS are the same two shapes spelled longer.</summary>
    public static string? Bound(string? method, string? description)
    {
        var value = description?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        var normalized = method?.Trim() ?? string.Empty;
        return normalized.StartsWith("RANGE", StringComparison.OrdinalIgnoreCase) ? $"VALUES LESS THAN ({value})"
            : normalized.StartsWith("LIST", StringComparison.OrdinalIgnoreCase) ? $"VALUES IN ({value})"
            : value;
    }

    // Engine, charset, collation and row format are bare words in MySQL's grammar; anything else would end the clause.
    private static string Word(TableOptionChange change, string name)
    {
        var value = change.After?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            throw new ArgumentException(CoreStrings.Format("Driver/OptionNeedsValue", name));
        }

        foreach (var c in value)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '_')
            {
                throw new ArgumentException(CoreStrings.Format("Driver/OptionInvalidValue", value, name));
            }
        }

        return value;
    }

    private static string PositiveNumber(TableOptionChange change, string name) =>
        ulong.TryParse(change.After?.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value > 0
            ? value.ToString(CultureInfo.InvariantCulture)
            : throw new ArgumentException(CoreStrings.Format("Driver/OptionPositiveWholeNumber", name));

    public static string CreateDatabase(string name) => "CREATE DATABASE " + Q(name);

    public static string DropDatabase(string name) => "DROP DATABASE " + Q(name);

    private static string AlterTable(ObjectName table) => "ALTER TABLE " + Dialect.Qualify(table);

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string JoinQuoted(IReadOnlyList<string> names)
    {
        var sql = new StringBuilder();
        for (var i = 0; i < names.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(", ");
            }

            sql.Append(Q(names[i]));
        }

        return sql.ToString();
    }
}
