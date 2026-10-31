using System.Data.Common;
using Microsoft.Data.Sqlite;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// Browsing, counting and the catalog over one projection, through the shared ADO.NET session. Every connection is
/// opened <c>query_only</c>, so nothing written through it can reach the projection.
/// </summary>
internal sealed class BeancountSqlSession(ConnectionRequest request, string connectionString) : AdoNetSession(request, BeancountDialect.Instance)
{
    private const string Objects = """
        SELECT name, type FROM sqlite_master
        WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite!_%' ESCAPE '!'
        ORDER BY name
        """;

    private const string Columns = """SELECT name, type, "notnull", dflt_value, pk FROM pragma_table_info(@table) ORDER BY cid""";

    private const string Definition = "SELECT type, sql FROM sqlite_master WHERE name = @name AND type IN ('table', 'view')";

    protected override DbConnection CreateConnection() => new SqliteConnection(connectionString);

    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA query_only = ON";
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            Objects,
            static r => new DatabaseObject(new ObjectName(null, r.GetString(0)), r.GetString(1) == "view" ? ObjectKind.View : ObjectKind.Table),
            cancellationToken);

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            Columns,
            static r => (Name: r.GetString(0), Type: r.IsDBNull(1) ? string.Empty : r.GetString(1), NotNull: r.GetInt64(2) != 0, Default: NullableString(r, 3), PrimaryKey: r.GetInt64(4) != 0),
            cancellationToken,
            ("@table", table.Name));

        var columns = new ColumnInfo[rows.Count];
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            columns[i] = new ColumnInfo(row.Name, row.Type, !row.NotNull, row.Default, row.PrimaryKey, IsIdentity: false, i);
        }

        return columns;
    }

    // The projection has no indexes or keys beyond each table's primary key, which the columns already mark.
    protected override Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<IndexInfo>>([]);

    protected override Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<ForeignKeyInfo>>([]);

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            Definition,
            static r => (Type: r.GetString(0), Sql: NullableString(r, 1)),
            cancellationToken,
            ("@name", obj.Name.Name));
        if (rows.Count == 0 || rows[0].Sql is not { } sql)
        {
            throw new BeancountException(BeancountStrings.Format("Beancount/NoDdl", obj.Name.Name));
        }

        return rows[0].Type == "table" && !sql.EndsWith(';') ? sql + ";" : sql;
    }
}
