using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <summary>One DDL statement of a migration, with what it does and whether it loses data.</summary>
public sealed record MigrationStatement(ObjectName Table, string Sql, string Summary, bool IsDestructive);

/// <summary>A migration script, and the edits the target engine could not express.</summary>
public sealed record MigrationScript(IReadOnlyList<MigrationStatement> Statements, IReadOnlyList<string> Unsupported);

/// <summary>
/// Turns a structure comparison into the target engine's DDL through its <see cref="ISchemaDdlProvider"/>, the same
/// generator the structure tab uses.
/// </summary>
/// <remarks>
/// The script runs in phases rather than table by table, which is what lets it skip a foreign-key sort for creates:
/// foreign keys are dropped first and added last, after every table and column they could name exists. Only
/// dropped tables are ordered, children before the parents they reference.
/// </remarks>
public static class SchemaMigrationBuilder
{
    public static MigrationScript Build(IReadOnlyList<TableSchemaDiff> diffs, ISchemaDdlProvider target, string? targetSchema, SchemaCompareOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(diffs);
        ArgumentNullException.ThrowIfNull(target);
        options ??= SchemaCompareOptions.Default;

        var statements = new List<MigrationStatement>();
        var unsupported = new List<string>();

        void Emit(ObjectName table, SchemaChange change)
        {
            var sql = target.BuildDdl(table, change);
            if (sql.Count == 0)
            {
                unsupported.Add(CoreStrings.Format("Compare/TableNote", table.Name, Describe(change)));
                return;
            }

            var destructive = change is DropColumn or DropObject;
            statements.AddRange(sql.Select(s => new MigrationStatement(table, s, Describe(change), destructive)));
        }

        var changed = diffs.Where(d => d.Kind == SchemaDiffKind.Changed && d.Target is not null).ToArray();
        var created = diffs.Where(d => d.Kind == SchemaDiffKind.OnlyInSource && d.Source is not null).ToArray();

        foreach (var diff in changed)
        {
            foreach (var change in diff.Changes.OfType<DropForeignKey>())
            {
                Emit(diff.Target!.Table, change);
            }
        }

        if (options.DropExtraTables)
        {
            var dropped = diffs.Where(d => d.Kind == SchemaDiffKind.OnlyInTarget && d.Target is not null).Select(d => d.Target!).ToList();
            foreach (var table in ChildrenFirst(dropped, options))
            {
                Emit(table.Table, new DropObject(new DatabaseObject(table.Table, ObjectKind.Table)));
            }
        }

        foreach (var diff in changed)
        {
            foreach (var change in diff.Changes.Where(c => c is not (DropForeignKey or AddForeignKey)).OrderBy(Phase))
            {
                Emit(diff.Target!.Table, change);
            }
        }

        foreach (var diff in created)
        {
            var source = diff.Source!;
            var table = new ObjectName(targetSchema, source.Table.Name);
            var columns = source.Columns.OrderBy(c => c.Ordinal).Select(ColumnDefinition.From).ToArray();
            Emit(table, new CreateTable(table, columns));
            if (options.CompareIndexes)
            {
                foreach (var index in source.Indexes.Where(i => !i.IsPrimary))
                {
                    Emit(table, new CreateIndex(new IndexDefinition(index.Name, index.Columns, index.IsUnique)));
                }
            }
        }

        if (options.CompareForeignKeys)
        {
            foreach (var diff in created)
            {
                var table = new ObjectName(targetSchema, diff.Source!.Table.Name);
                foreach (var key in diff.Source.ForeignKeys)
                {
                    Emit(table, new AddForeignKey(SchemaDiffEngine.ForeignKeyFor(key, targetSchema)));
                }
            }

            foreach (var diff in changed)
            {
                foreach (var change in diff.Changes.OfType<AddForeignKey>())
                {
                    Emit(diff.Target!.Table, change);
                }
            }
        }

        return new MigrationScript(statements, unsupported);
    }

    /// <summary>What a change does, in a line.</summary>
    public static string Describe(SchemaChange change) => change switch
    {
        CreateTable create => CoreStrings.Format("Compare/ChangeCreateTable", create.Table.Name),
        AddColumn add => CoreStrings.Format("Compare/ChangeAddColumn", add.Column.Name, add.Column.DataType),
        DropColumn drop => CoreStrings.Format("Compare/ChangeDropColumn", drop.Column),

        // NOT NULL is part of the type as SQL spells it, so it stays English beside the data type.
        AlterColumn alter => CoreStrings.Format("Compare/ChangeAlterColumn", alter.After.Name, alter.After.IsNullable ? alter.After.DataType : alter.After.DataType + " NOT NULL"),
        RenameColumn rename => CoreStrings.Format("Compare/ChangeRenameColumn", rename.From, rename.To),
        CreateIndex index => CoreStrings.Format(index.Index.IsUnique ? "Compare/ChangeCreateUniqueIndex" : "Compare/ChangeCreateIndex", index.Index.Name),
        DropIndex index => CoreStrings.Format("Compare/ChangeDropIndex", index.Index),
        AddForeignKey key => CoreStrings.Format("Compare/ChangeAddForeignKey", key.ForeignKey.Name, key.ForeignKey.ReferencedTable.Name),
        DropForeignKey key => CoreStrings.Format("Compare/ChangeDropForeignKey", key.Name),
        DropObject drop => DescribeDrop(drop.Object),
        RenameTable rename => CoreStrings.Format("Compare/ChangeRenameTable", rename.NewName),
        TruncateTable => CoreStrings.Get("Compare/ChangeTruncateTable"),
        _ => change.GetType().Name,
    };

    // A kind is named in the sentence itself, since a translated sentence cannot take an English kind name.
    private static string DescribeDrop(DatabaseObject obj) => obj.Kind switch
    {
        ObjectKind.Table => CoreStrings.Format("Compare/ChangeDropTable", obj.Name.Name),
        ObjectKind.View => CoreStrings.Format("Compare/ChangeDropView", obj.Name.Name),
        ObjectKind.MaterializedView => CoreStrings.Format("Compare/ChangeDropMaterializedView", obj.Name.Name),
        ObjectKind.Function => CoreStrings.Format("Compare/ChangeDropFunction", obj.Name.Name),
        ObjectKind.Procedure => CoreStrings.Format("Compare/ChangeDropProcedure", obj.Name.Name),
        ObjectKind.Sequence => CoreStrings.Format("Compare/ChangeDropSequence", obj.Name.Name),
        ObjectKind.Trigger => CoreStrings.Format("Compare/ChangeDropTrigger", obj.Name.Name),
        _ => CoreStrings.Format("Compare/ChangeDropObject", obj.Name.Name),
    };

    // Inside one table: make room before adding, so a recreated index never collides with the one it replaces.
    private static int Phase(SchemaChange change) => change switch
    {
        DropIndex => 0,
        DropColumn => 1,
        AlterColumn => 2,
        AddColumn => 3,
        CreateIndex => 4,
        _ => 5,
    };

    private static List<TableStructure> ChildrenFirst(List<TableStructure> tables, SchemaCompareOptions options)
    {
        var ordered = new List<TableStructure>(tables.Count);
        var remaining = new List<TableStructure>(tables);
        while (remaining.Count > 0)
        {
            // A table goes once no other remaining table references it; a cycle falls back to the given order.
            var next = remaining.FirstOrDefault(t => !remaining.Any(other => !ReferenceEquals(other, t)
                && other.ForeignKeys.Any(k => string.Equals(k.ReferencedTable.Name, t.Table.Name, options.NameComparison)))) ?? remaining[0];
            ordered.Add(next);
            remaining.Remove(next);
        }

        return ordered;
    }
}
