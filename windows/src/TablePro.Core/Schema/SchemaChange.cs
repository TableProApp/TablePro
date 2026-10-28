namespace TablePro.Core.Schema;

/// <summary>A column as the structure editor and the create-table form describe it.</summary>
public sealed record ColumnDefinition(
    string Name,
    string DataType,
    bool IsNullable = true,
    string? DefaultExpression = null,
    bool IsPrimaryKey = false,
    bool IsIdentity = false,
    string? Comment = null)
{
    public static ColumnDefinition From(ColumnInfo column) =>
        new(column.Name, column.DataType, column.IsNullable, column.DefaultValue, column.IsPrimaryKey, column.IsIdentity, column.Comment);
}

public sealed record IndexDefinition(string Name, IReadOnlyList<string> Columns, bool IsUnique = false);

public sealed record ForeignKeyDefinition(
    string Name,
    IReadOnlyList<string> Columns,
    ObjectName ReferencedTable,
    IReadOnlyList<string> ReferencedColumns,
    string? OnDelete = null,
    string? OnUpdate = null);

/// <summary>One edit from the structure tab, turned into DDL by the engine's <see cref="Drivers.ISchemaDdlProvider"/>.</summary>
public abstract record SchemaChange;

public sealed record CreateTable(ObjectName Table, IReadOnlyList<ColumnDefinition> Columns) : SchemaChange;

public sealed record AddColumn(ColumnDefinition Column) : SchemaChange;

public sealed record DropColumn(string Column) : SchemaChange;

public sealed record RenameColumn(string From, string To) : SchemaChange;

/// <summary>Changes type, nullability, default or comment. The name stays; a rename is its own change.</summary>
public sealed record AlterColumn(ColumnDefinition Before, ColumnDefinition After) : SchemaChange;

public sealed record CreateIndex(IndexDefinition Index) : SchemaChange;

public sealed record DropIndex(string Index) : SchemaChange;

public sealed record AddForeignKey(ForeignKeyDefinition ForeignKey) : SchemaChange;

public sealed record DropForeignKey(string Name) : SchemaChange;

public sealed record RenameTable(string NewName) : SchemaChange;

public sealed record DropObject(DatabaseObject Object, bool Cascade = false) : SchemaChange;

public sealed record TruncateTable(bool Cascade = false) : SchemaChange;
