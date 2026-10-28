using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite;

/// <summary>Check constraints and table options for the structure tab.</summary>
public sealed partial class SqliteSession : ITableDetailsProvider
{
    public StructureEdits SupportedEdits => StructureEdits.CheckConstraints;

    public Task<TableDetails> GetTableDetailsAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var schema = Dialect.QuoteIdentifier(SqliteCatalog.SchemaOrMain(table.Schema));
                if (await ScalarAsync(connection, SqliteCatalog.TableSql(schema), ct, ("@table", table.Name)) is not string sql
                    || SqliteTableDdl.Parse(sql) is not { } create)
                {
                    return TableDetails.Empty;
                }

                var checks = SqliteTableDdl.CheckConstraints(create, table.Name).Select(c => new CheckConstraintInfo(c.Name, c.Expression)).ToArray();
                return new TableDetails(checks, null, SqliteDdl.ReadOptions(create));
            },
            cancellationToken);

    /// <summary>SQLite's ALTER TABLE cannot add or drop a constraint, so every check change rebuilds the table, as a foreign key does.</summary>
    private List<string> BuildCheckRebuild(ObjectName table, string? existing, CheckConstraintDefinition? replacement)
    {
        if (SqliteCatalog.AttachedSchema(table.Schema) is not null
            || ReadSnapshot(table.Name) is not { } snapshot
            || SqliteDdl.WithCheck(snapshot.Create, table.Name, existing, replacement) is not { } entries)
        {
            return [];
        }

        return SqliteDdl.Rebuild(snapshot, entries, snapshot.CopyableColumns, static _ => true);
    }
}
