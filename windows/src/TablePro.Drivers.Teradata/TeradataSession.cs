using System.Data.Common;
using System.Globalization;
using System.Text;
using Teradata.Client.Provider;
using TablePro.Core.Browse;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Teradata;

/// <summary>
/// Teradata through its .NET provider. Teradata has one namespace level, databases and users, which the sidebar shows
/// as schemas; the session opens on the login's default database.
/// </summary>
/// <remarks>
/// Core's count and save run unchanged: the provider binds <c>?</c> by position and does not require distinct
/// parameter names, and Core adds parameters in the order their markers appear. Browse adds a default sort first, so
/// the class re-implements <see cref="IDatabaseSession"/> to reach its own <see cref="BrowseAsync"/>.
/// </remarks>
public sealed class TeradataSession : AdoNetSession, IDatabaseSession, ISchemaDdlProvider, IUserListProvider
{
    private readonly string _connectionString;
    private readonly string[] _startupStatements;

    public TeradataSession(ConnectionRequest request)
        : base(request, TeradataDialect.Instance)
    {
        _connectionString = TeradataConnectionStringFactory.Build(request);
        _startupStatements = string.IsNullOrWhiteSpace(request.Profile.StartupCommands)
            ? []
            : SqlScript.Split(request.Profile.StartupCommands, Dialect).Select(s => s.Text).ToArray();
    }

    public override string? DefaultSchema => string.IsNullOrEmpty(CurrentDatabase) ? Profile.Username : CurrentDatabase;

    public IReadOnlyList<string> CommonDataTypes => TeradataDdl.CommonDataTypes;

    protected override DbConnection CreateConnection() => new TdConnection(_connectionString);

    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        foreach (var statement in _startupStatements)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = statement;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    protected override void AttachMessages(DbConnection connection, Action<string> onMessage) =>
        ((TdConnection)connection).InfoMessage += (_, e) => onMessage(e.Message);

    /// <summary>A Teradata system has no level above its databases, which the schema list already shows.</summary>
    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, TeradataCatalog.Schemas, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var database = Database(schema);
        return QueryAsync(
            connection,
            TeradataCatalog.Objects,
            r =>
            {
                var tableKind = r.GetString(1).Trim();
                var comment = NullableString(r, 2);
                return new DatabaseObject(
                    new ObjectName(database, r.GetString(0)),
                    TeradataDdl.KindOf(tableKind),
                    null,
                    tableKind == "M" ? TeradataDdl.MacroMarker : string.IsNullOrEmpty(comment) ? null : comment);
            },
            cancellationToken,
            ("database", database));
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var database = Database(table.Schema);
        var rows = await QueryAsync(
            connection,
            TeradataCatalog.Columns,
            static r =>
            {
                var identity = NullableString(r, 7)?.Trim() is "GA" or "GD";
                var defaultValue = NullableString(r, 6)?.Trim();
                var comment = NullableString(r, 8);
                var column = new ColumnInfo(
                    r.GetString(0),
                    TeradataDdl.TypeName(NullableString(r, 1), Int(r, 2), Int(r, 3), Int(r, 4), Int(r, 9)),
                    NullableString(r, 5)?.Trim() != "N",
                    string.IsNullOrEmpty(defaultValue) ? null : defaultValue,
                    false,
                    identity,
                    0,
                    string.IsNullOrEmpty(comment) ? null : comment);
                return (Column: column, KeyRank: r.IsDBNull(10) ? 0 : Int(r, 10));
            },
            cancellationToken,
            ("database", database),
            ("table", table.Name),
            ("database", database),
            ("table", table.Name));

        return KeyColumns(rows);
    }

    /// <summary>
    /// A PRIMARY KEY names the row; without one a unique primary index does. Both can exist on different columns, and
    /// marking both would key the grid on a composite neither of them is.
    /// </summary>
    internal static IReadOnlyList<ColumnInfo> KeyColumns(IReadOnlyList<(ColumnInfo Column, int KeyRank)> rows)
    {
        var best = 0;
        foreach (var row in rows)
        {
            if (row.KeyRank > 0 && (best == 0 || row.KeyRank < best))
            {
                best = row.KeyRank;
            }
        }

        var columns = new ColumnInfo[rows.Count];
        for (var i = 0; i < rows.Count; i++)
        {
            columns[i] = rows[i].Column with { IsPrimaryKey = best > 0 && rows[i].KeyRank == best, Ordinal = i };
        }

        return columns;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            TeradataCatalog.Indexes,
            static r => (Number: Int(r, 0), Name: NullableString(r, 1), Type: r.GetString(2).Trim(), Unique: NullableString(r, 3)?.Trim() == "Y", Column: r.GetString(4)),
            cancellationToken,
            Bind(table));

        return rows.GroupBy(r => r.Number)
            .Select(g =>
            {
                var first = g.First();
                var description = TeradataDdl.IndexDescription(first.Type);
                return new IndexInfo(
                    string.IsNullOrEmpty(first.Name) ? description : first.Name,
                    g.Select(r => r.Column).ToArray(),
                    first.Unique || first.Type is "K" or "U",
                    first.Type is "K" or "P" or "Q",
                    description);
            })
            .ToArray();
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            TeradataCatalog.ForeignKeys,
            static r => (Id: Int(r, 0), Name: NullableString(r, 1), Column: r.GetString(2), ParentDatabase: r.GetString(3), ParentTable: r.GetString(4), ParentColumn: r.GetString(5)),
            cancellationToken,
            Bind(table));

        // Teradata's references have no referential actions.
        return rows.GroupBy(r => r.Id)
            .Select(g =>
            {
                var first = g.First();
                return new ForeignKeyInfo(
                    first.Name ?? string.Create(CultureInfo.InvariantCulture, $"FK_{first.Id}"),
                    g.Select(r => r.Column).ToArray(),
                    new ObjectName(first.ParentDatabase, first.ParentTable),
                    g.Select(r => r.ParentColumn).ToArray(),
                    "NO ACTION",
                    "NO ACTION");
            })
            .ToArray();
    }

    protected override Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            TeradataCatalog.Triggers,
            static r => new TriggerInfo(
                r.GetString(0),
                TeradataDdl.TriggerTiming(NullableString(r, 1)),
                TeradataDdl.TriggerEvent(NullableString(r, 2)),
                NormalizeLines(NullableString(r, 4))),
            cancellationToken,
            Bind(table));

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var name = obj.Name with { Schema = Database(obj.Name.Schema) };
        var kind = await ScalarAsync(connection, TeradataCatalog.TableKind, cancellationToken, ("database", name.Schema), ("table", name.Name)) as string
            ?? throw new InvalidOperationException($"No definition was found for {obj.Name}.");
        var show = TeradataDdl.ShowStatement(kind, name) ?? throw new NotSupportedException($"Teradata has no SHOW statement for {obj.Name}.");

        // SHOW answers in one or more rows of text with CR line ends.
        var parts = await QueryAsync(connection, show, static r => NullableString(r, 0) ?? string.Empty, cancellationToken);
        var sql = new StringBuilder();
        foreach (var part in parts)
        {
            sql.Append(part);
        }

        return NormalizeLines(sql.ToString())!.Trim();
    }

    /// <summary>
    /// A page after the first numbers its rows over the sort, and Teradata gives unsorted rows no stable order, so an
    /// unsorted browse is sorted by the table's key, or by its first column when it has none, as the macOS app does.
    /// The first page reads <c>TOP n</c> and needs no order.
    /// </summary>
    public new Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Sort.Count > 0 || request.Offset <= 0)
        {
            return base.BrowseAsync(request, cancellationToken);
        }

        return WithConnectionAsync(
            async (connection, ct) =>
            {
                var sorted = request with { Sort = DefaultSort(await LoadColumnsAsync(connection, request.Table, ct)) };
                await using var command = CreateCommand(connection, Dialect.BuildBrowse(sorted));
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, request.Limit, ct);
            },
            cancellationToken);
    }

    internal static SortColumn[] DefaultSort(IReadOnlyList<ColumnInfo> columns)
    {
        var keys = columns.Where(c => c.IsPrimaryKey).Select(c => new SortColumn(c.Name, false)).ToArray();
        return keys.Length > 0 ? keys : columns.Count > 0 ? [new SortColumn(columns[0].Name, false)] : [];
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) =>
        TeradataDdl.Build(table.Schema is null ? table with { Schema = DefaultSchema } : table, change);

    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = connection.CreateCommand();
                command.CommandText = TeradataCatalog.Users;
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, int.MaxValue, ct);
            },
            cancellationToken);

    internal static string? NormalizeLines(string? text) =>
        text?.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');

    private (string, object?)[] Bind(ObjectName table) => [("database", Database(table.Schema)), ("table", table.Name)];

    private string Database(string? schema) =>
        !string.IsNullOrEmpty(schema) ? schema : DefaultSchema ?? throw new InvalidOperationException("No database was given and the login has no default.");

    private static int Int(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? 0 : Convert.ToInt32(reader.GetValue(ordinal), CultureInfo.InvariantCulture);
}
