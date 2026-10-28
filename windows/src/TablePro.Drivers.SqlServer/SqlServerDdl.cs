using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.SqlServer;

/// <summary>The T-SQL statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class SqlServerDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "int", "bigint", "nvarchar(255)", "nvarchar(max)", "varchar(255)", "bit", "datetime2(7)", "date", "decimal(18,2)",
        "uniqueidentifier", "smallint", "tinyint", "float", "real", "datetimeoffset(7)", "time(7)", "varbinary(max)", "money", "xml",
    ];

    private static SqlDialect Dialect => SqlServerDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => CreateTable(create),
        AddColumn add => AddColumn(table, add.Column),
        DropColumn drop => [DropDefaultConstraint(table, drop.Column), string.Concat(AlterTable(table), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [RenameColumn(table, rename.From, rename.To)],
        AlterColumn alter => AlterColumn(table, alter.Before, alter.After),
        CreateIndex index => [CreateIndex(table, index.Index)],
        DropIndex index => [DropIndex(table, index.Index)],
        AddForeignKey key => [string.Concat(AlterTable(table), " ADD ", ForeignKey(table, key.ForeignKey))],
        DropForeignKey key => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(key.Name))],
        RenameTable rename => [string.Concat("EXEC sys.sp_rename ", Literal(Dialect.Qualify(table)), ", ", Literal(rename.NewName))],
        DropObject drop => DropObject(drop.Object) is { } sql ? [sql] : [],
        TruncateTable => ["TRUNCATE TABLE " + Dialect.Qualify(table)],
        AddCheckConstraint add => add.Constraint.IsComplete ? [string.Concat(AlterTable(table), " ADD ", CheckClause(add.Constraint))] : [],
        DropCheckConstraint drop => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(drop.Name))],
        AlterCheckConstraint alter => AlterCheck(table, alter),
        SetTableOptions options => SetOptions(table, options.Changes),

        // A partition here belongs to a partition scheme shared by tables, so it is changed there, not on one table.
        _ => [],
    };

    public static string ColumnSql(ObjectName table, ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(column.DataType.Trim());
        if (column.IsIdentity)
        {
            sql.Append(" IDENTITY(1,1)");
        }

        sql.Append(column.IsNullable && !inlinePrimaryKey ? " NULL" : " NOT NULL");
        if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" CONSTRAINT ").Append(Q(DefaultConstraintName(table, column.Name))).Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");
        }

        return sql.ToString();
    }

    public static List<string> CreateTable(CreateTable change)
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
            sql.Append(ColumnSql(change.Table, column, primaryKey.Count == 1 && column.IsPrimaryKey));
        }

        if (primaryKey.Count > 1)
        {
            sql.Append(",\n  CONSTRAINT ").Append(Q("PK_" + change.Table.Name)).Append(" PRIMARY KEY (").Append(JoinQuoted(primaryKey)).Append(')');
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
        var statements = new List<string>(2) { string.Concat(AlterTable(table), " ADD ", ColumnSql(table, column, column.IsPrimaryKey)) };
        if (!string.IsNullOrEmpty(column.Comment))
        {
            statements.Add(ColumnComment(table, column.Name, column.Comment));
        }

        return statements;
    }

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat("EXEC sys.sp_rename ", Literal(string.Concat(Dialect.Qualify(table), ".", Q(from))), ", ", Literal(to), ", N'COLUMN'");

    /// <summary>
    /// ALTER COLUMN restates the type and nullability together. A default is a named constraint in SQL Server, so a
    /// changed default drops whatever constraint the column has and adds a new one. An identity cannot be added to or
    /// removed from an existing column, so that part of the change has no statement.
    /// </summary>
    public static List<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var statements = new List<string>(5);
        if (!string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase) || before.IsNullable != after.IsNullable)
        {
            statements.Add(string.Concat(
                AlterTable(table), " ALTER COLUMN ", Q(before.Name), " ", after.DataType.Trim(), after.IsNullable ? " NULL" : " NOT NULL"));
        }

        if (!string.Equals(before.DefaultExpression?.Trim(), after.DefaultExpression?.Trim(), StringComparison.Ordinal))
        {
            statements.Add(DropDefaultConstraint(table, before.Name));
            if (!string.IsNullOrWhiteSpace(after.DefaultExpression))
            {
                statements.Add(string.Concat(
                    AlterTable(table), " ADD CONSTRAINT ", Q(DefaultConstraintName(table, before.Name)), " DEFAULT ",
                    after.DefaultExpression.Trim(), " FOR ", Q(before.Name)));
            }
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

    /// <summary>
    /// SQL Server refuses to drop a column, or change its default, while a default constraint is bound to it, and the
    /// constraint's name is whatever the server generated, so the batch looks it up.
    /// </summary>
    public static string DropDefaultConstraint(ObjectName table, string column)
    {
        var qualified = Dialect.Qualify(table);
        return string.Concat(
            "DECLARE @constraint sysname;\n",
            "SELECT @constraint = dc.name FROM sys.default_constraints dc\n",
            "JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id\n",
            "WHERE dc.parent_object_id = OBJECT_ID(", Literal(qualified), ") AND c.name = ", Literal(column), ";\n",
            "IF @constraint IS NOT NULL EXEC (N'ALTER TABLE ' + ", Literal(qualified), " + N' DROP CONSTRAINT ' + QUOTENAME(@constraint));");
    }

    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat(
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Q(index.Name), " ON ", Dialect.Qualify(table),
            " (", JoinQuoted(index.Columns), ")");

    // DROP INDEX refuses the index behind a PRIMARY KEY or UNIQUE constraint; the constraint has to be dropped instead.
    public static string DropIndex(ObjectName table, string index)
    {
        var qualified = Dialect.Qualify(table);
        return string.Concat(
            "IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(", Literal(qualified), ") AND name = ", Literal(index), ")\n",
            "    ALTER TABLE ", qualified, " DROP CONSTRAINT ", Q(index), "\n",
            "ELSE\n",
            "    DROP INDEX ", Q(index), " ON ", qualified);
    }

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
        AppendAction(sql, " ON DELETE ", key.OnDelete);
        AppendAction(sql, " ON UPDATE ", key.OnUpdate);
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
            ObjectKind.Sequence => "SEQUENCE",
            ObjectKind.Trigger => "TRIGGER",
            _ => null,
        };

        return keyword is null ? null : string.Concat("DROP ", keyword, " ", Dialect.Qualify(obj.Name));
    }

    /// <summary>A column description is the MS_Description extended property, added, updated or dropped as it stands.</summary>
    public static string ColumnComment(ObjectName table, string column, string? comment)
    {
        var target = string.Concat(
            "@level0type = N'SCHEMA', @level0name = ", Literal(table.Schema ?? "dbo"),
            ", @level1type = N'TABLE', @level1name = ", Literal(table.Name),
            ", @level2type = N'COLUMN', @level2name = ", Literal(column));
        var exists = string.Concat(
            "IF EXISTS (SELECT 1 FROM sys.fn_listextendedproperty(N'MS_Description', N'SCHEMA', ", Literal(table.Schema ?? "dbo"),
            ", N'TABLE', ", Literal(table.Name), ", N'COLUMN', ", Literal(column), "))\n");
        if (string.IsNullOrEmpty(comment))
        {
            return string.Concat(exists, "    EXEC sys.sp_dropextendedproperty @name = N'MS_Description', ", target);
        }

        var value = "@value = " + Literal(comment);
        return string.Concat(
            exists,
            "    EXEC sys.sp_updateextendedproperty @name = N'MS_Description', ", value, ", ", target, "\n",
            "ELSE\n",
            "    EXEC sys.sp_addextendedproperty @name = N'MS_Description', ", value, ", ", target);
    }

    /// <summary>A table description is the MS_Description property at table level, added, updated or dropped as it stands.</summary>
    public static string TableComment(ObjectName table, string? comment)
    {
        var target = string.Concat(
            "@level0type = N'SCHEMA', @level0name = ", Literal(table.Schema ?? "dbo"),
            ", @level1type = N'TABLE', @level1name = ", Literal(table.Name));
        var exists = string.Concat(
            "IF EXISTS (SELECT 1 FROM sys.fn_listextendedproperty(N'MS_Description', N'SCHEMA', ", Literal(table.Schema ?? "dbo"),
            ", N'TABLE', ", Literal(table.Name), ", NULL, NULL))\n");
        if (string.IsNullOrEmpty(comment))
        {
            return string.Concat(exists, "    EXEC sys.sp_dropextendedproperty @name = N'MS_Description', ", target);
        }

        var value = "@value = " + Literal(comment);
        return string.Concat(
            exists,
            "    EXEC sys.sp_updateextendedproperty @name = N'MS_Description', ", value, ", ", target, "\n",
            "ELSE\n",
            "    EXEC sys.sp_addextendedproperty @name = N'MS_Description', ", value, ", ", target);
    }

    public static readonly IReadOnlyList<TableOptionSpec> TableOptionSpecs =
    [
        new(TableOptionNames.Comment, TableOptionKind.Text),
        new(TableOptionNames.DataCompression, TableOptionKind.Choice, ["NONE", "ROW", "PAGE"]),
        new(TableOptionNames.LockEscalation, TableOptionKind.Choice, ["TABLE", "AUTO", "DISABLE"]),
    ];

    public static string CheckClause(CheckConstraintDefinition check) =>
        string.Concat("CONSTRAINT ", Q(check.Name.Trim()), " CHECK (", check.Expression.Trim(), ")");

    /// <summary>
    /// A rename is sp_rename on the constraint, which leaves the rows unread. T-SQL cannot drop and add in one ALTER
    /// TABLE, so a new expression takes two statements.
    /// </summary>
    public static List<string> AlterCheck(ObjectName table, AlterCheckConstraint alter)
    {
        if (alter.IsRenameOnly)
        {
            return
            [
                string.Concat(
                    "EXEC sys.sp_rename ", Literal(Dialect.Qualify(table with { Name = alter.Before.Name })), ", ",
                    Literal(alter.After.Name.Trim()), ", N'OBJECT'"),
            ];
        }

        return alter.After.IsComplete
            ? [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(alter.Before.Name)), string.Concat(AlterTable(table), " ADD ", CheckClause(alter.After))]
            : [];
    }

    public static List<string> SetOptions(ObjectName table, IReadOnlyList<TableOptionChange> changes)
    {
        var statements = new List<string>(changes.Count);
        foreach (var change in changes)
        {
            switch (change.Name)
            {
                case TableOptionNames.Comment:
                    statements.Add(TableComment(table, change.After?.Trim()));
                    break;

                // Compression is a property of the stored rows, so changing it rewrites the table.
                case TableOptionNames.DataCompression:
                    statements.Add(string.Concat(AlterTable(table), " REBUILD WITH (DATA_COMPRESSION = ", Keyword(change, ["NONE", "ROW", "PAGE"]), ")"));
                    break;
                case TableOptionNames.LockEscalation:
                    statements.Add(string.Concat(AlterTable(table), " SET (LOCK_ESCALATION = ", Keyword(change, ["TABLE", "AUTO", "DISABLE"]), ")"));
                    break;
            }
        }

        return statements;
    }

    public static List<TableOption> ReadOptions(string? comment, string? lockEscalation, string? compression, string? filegroup) =>
    [
        new(TableOptionNames.Comment, comment),
        new(TableOptionNames.DataCompression, compression),
        new(TableOptionNames.LockEscalation, lockEscalation),
        new(TableOptionNames.Filegroup, filegroup),
    ];

    private static string Keyword(TableOptionChange change, string[] allowed)
    {
        var value = change.After?.Trim().ToUpperInvariant();
        return value is not null && Array.IndexOf(allowed, value) >= 0
            ? value
            : throw new ArgumentException($"{change.Name} is one of {string.Join(", ", allowed)}.");
    }

    public static string Kill(object processId) =>
        "KILL " + Convert.ToInt32(processId, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);

    public static string CreateDatabase(string name) => "CREATE DATABASE " + Q(name);

    public static string DropDatabase(string name) => "DROP DATABASE " + Q(name);

    public static string ReferentialAction(string description) => description.Replace('_', ' ');

    private static string DefaultConstraintName(ObjectName table, string column) => string.Concat("DF_", table.Name, "_", column);

    private static void AppendAction(StringBuilder sql, string clause, string? action)
    {
        if (!string.IsNullOrWhiteSpace(action) && !string.Equals(action.Trim(), "NO ACTION", StringComparison.OrdinalIgnoreCase))
        {
            sql.Append(clause).Append(action.Trim().ToUpperInvariant());
        }
    }

    private static string AlterTable(ObjectName table) => "ALTER TABLE " + Dialect.Qualify(table);

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string Literal(string value) => Dialect.StringLiteral(value);

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
