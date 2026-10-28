using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.MySql;

/// <summary>The MySQL and MariaDB statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class MySqlDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "INT", "BIGINT", "VARCHAR(255)", "TEXT", "DATETIME", "TIMESTAMP", "DATE", "DECIMAL(12,2)", "TINYINT(1)", "JSON",
        "INT UNSIGNED", "BIGINT UNSIGNED", "SMALLINT", "DOUBLE", "FLOAT", "CHAR(36)", "LONGTEXT", "BLOB", "TIME", "ENUM('a','b')",
    ];

    private static SqlDialect Dialect => MySqlDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change) => change switch
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
