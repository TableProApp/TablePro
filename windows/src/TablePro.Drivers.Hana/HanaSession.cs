using System.Data.Common;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Odbc;

namespace TablePro.Drivers.Hana;

/// <summary>
/// SAP HANA through SAP's HDBODBC driver. Schemas are the sidebar's level; the session opens on the Database field's
/// schema, set with <c>SET SCHEMA</c> on every connection, or the login's own when it is empty.
/// </summary>
/// <remarks>
/// Core's HANA dialect already writes <c>?</c>, so browse, count and save bind positionally as Core built them. Unlike
/// the macOS driver, which has no transactions, saves run in one ODBC transaction. A read-only profile sets the session's
/// access mode to READ ONLY on every connection, beyond the save refusal and the app's Safe Mode.
/// </remarks>
internal sealed class HanaSession
    : OdbcSession, ISchemaDdlProvider, IServerActivityProvider, IServerVariablesProvider, IUserListProvider
{
    private const string ExplainPrefix = "EXPLAIN PLAN FOR ";

    private readonly string[] _connectionSetup;
    private string? _defaultSchema;

    public HanaSession(ConnectionRequest request)
        : base(request, HanaDialect.Instance, HanaConnectionStringFactory.Driver, HanaConnectionStringFactory.Build(request))
    {
        _defaultSchema = string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim();
        _connectionSetup = Setup(_defaultSchema, request.Profile.IsReadOnly);
    }

    public override string? DefaultSchema => _defaultSchema;

    public IReadOnlyList<string> CommonDataTypes => HanaDdl.CommonDataTypes;

    public string ProcessIdColumn => "CONNECTION_ID";

    protected override string PingSql => HanaCatalog.Ping;

    protected override IReadOnlyList<string> ConnectionSetup => _connectionSetup;

    /// <summary>
    /// The statements every connection runs. SET SCHEMA takes the quoted name, which keeps a mixed-case schema exact
    /// where the CURRENTSCHEMA keyword would leave the spelling to the client.
    /// </summary>
    internal static string[] Setup(string? schema, bool readOnly)
    {
        var statements = new List<string>(2);
        if (!string.IsNullOrEmpty(schema))
        {
            statements.Add("SET SCHEMA " + HanaDialect.Instance.QuoteIdentifier(schema));
        }

        if (readOnly)
        {
            statements.Add(HanaCatalog.ReadOnly);
        }

        return [.. statements];
    }

    protected override async Task OnConnectedAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        _defaultSchema ??= await TextAsync(connection, HanaCatalog.CurrentSchema, cancellationToken);
        CurrentDatabase = await TryTextAsync(connection, HanaCatalog.DatabaseName, cancellationToken) ?? CurrentDatabase;
    }

    /// <summary>
    /// Core's HANA dialect explains into the shared plan table and reads every row in it. The exact pair it wrote is
    /// run under a statement name of its own instead, read back by that name, and deleted afterwards, as the macOS
    /// driver does, so one plan never shows another's operators.
    /// </summary>
    internal override OdbcBatch PrepareBatch(IReadOnlyList<string> statements)
    {
        if (statements.Count == 2 && statements[0].StartsWith(ExplainPrefix, StringComparison.Ordinal))
        {
            var inner = statements[0][ExplainPrefix.Length..];
            if (HanaDialect.Instance.Explain(inner).SequenceEqual(statements, StringComparer.Ordinal))
            {
                return Explain(inner, "TABLEPRO_" + Guid.NewGuid().ToString("N")[..20].ToUpperInvariant());
            }
        }

        return OdbcBatch.Unchanged(statements);
    }

    internal static OdbcBatch Explain(string statement, string statementName)
    {
        var name = HanaDialect.Instance.StringLiteral(statementName);
        var body = statement.Trim().TrimEnd(';').TrimEnd();
        return new OdbcBatch(
            [
                string.Concat("EXPLAIN PLAN SET STATEMENT_NAME = ", name, " FOR ", body),
                string.Concat("SELECT ", HanaCatalog.ExplainPlanColumns, " FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = ", name, " ORDER BY OPERATOR_ID"),
            ],
            [string.Concat("DELETE FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = ", name)]);
    }

    /// <summary>A connection reaches one tenant database, which the switcher has nothing to switch to.</summary>
    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override async Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        var rows = await RowsAsync(connection, HanaCatalog.Schemas, cancellationToken);
        return HanaCatalog.UserSchemas(rows.Select(r => CatalogValues.Text(r[0]) ?? string.Empty), _defaultSchema);
    }

    protected override async Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var owner = Owner(schema);
        var rows = await RowsAsync(connection, HanaCatalog.Objects, cancellationToken, owner, owner, owner, owner, owner, owner, owner);
        return rows.Select(r => HanaCatalog.MapObject(owner, r)).ToArray();
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await ColumnRowsAsync(connection, table, cancellationToken);
        var columns = new ColumnInfo[rows.Count];
        for (var i = 0; i < columns.Length; i++)
        {
            columns[i] = HanaCatalog.MapColumn(rows[i], i);
        }

        return columns;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        HanaCatalog.MapIndexes(await RowsAsync(connection, HanaCatalog.Indexes, cancellationToken, Owner(table.Schema), table.Name));

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        HanaCatalog.MapForeignKeys(await RowsAsync(connection, HanaCatalog.ForeignKeys, cancellationToken, Owner(table.Schema), table.Name));

    protected override async Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await RowsAsync(connection, HanaCatalog.TableTriggers, cancellationToken, Owner(table.Schema), table.Name);
        return rows.Select(HanaCatalog.MapTrigger).ToArray();
    }

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var name = obj.Name with { Schema = Owner(obj.Name.Schema) };
        var schema = name.Schema!;
        switch (obj.Kind)
        {
            case ObjectKind.Table:
                return await TableDefinitionAsync(connection, name, cancellationToken);
            case ObjectKind.View:
                return CatalogValues.NonEmpty(await TextAsync(connection, HanaCatalog.ViewDefinition, cancellationToken, schema, name.Name)) is { } query
                    ? HanaDdl.ViewDefinition(name, query)
                    : throw Missing(obj);
            case ObjectKind.Sequence:
                var sequence = await RowsAsync(connection, HanaCatalog.Sequence, cancellationToken, schema, name.Name);
                return sequence.Count > 0 ? HanaDdl.SequenceDefinition(name, sequence[0]) : throw Missing(obj);
            case ObjectKind.Procedure or ObjectKind.Function or ObjectKind.Trigger:
                var sql = obj.Kind switch
                {
                    ObjectKind.Procedure => HanaCatalog.ProcedureDefinition,
                    ObjectKind.Function => HanaCatalog.FunctionDefinition,
                    _ => HanaCatalog.TriggerDefinition,
                };
                return CatalogValues.NonEmpty(await TextAsync(connection, sql, cancellationToken, schema, name.Name)) is { } definition
                    ? HanaDdl.StoredDefinition(definition)
                    : throw new InvalidOperationException($"SAP HANA returned no definition for {obj.Name}; the login may lack the privilege to read it.");
            default:
                throw new NotSupportedException($"SAP HANA has no definition for a {obj.Kind}.");
        }
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) =>
        HanaDdl.Build(table.Schema is null ? table with { Schema = _defaultSchema } : table, change);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(HanaCatalog.Activity, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken) => RunAsync(HanaDdl.Kill(processId), cancellationToken);

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) =>
        ReadFirstAsync(HanaCatalog.Variables, HanaCatalog.SystemOverview, cancellationToken);

    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) => ReadResultAsync(HanaCatalog.Users, cancellationToken);

    /// <summary>
    /// GET_OBJECT_DEFINITION is HANA's own DDL, partitions and all; a login it is closed to gets the statement rebuilt
    /// from the catalog, as on macOS.
    /// </summary>
    private async Task<string> TableDefinitionAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        try
        {
            var rows = await RowsAsync(connection, HanaCatalog.ObjectDefinition, cancellationToken, table.Schema, table.Name);
            if (rows.Count > 0 && rows[0].Length >= 4 && CatalogValues.NonEmpty(rows[0][3]) is { } statement)
            {
                return statement;
            }
        }
        catch (OdbcDriverException)
        {
            // Not granted, or an older server: the catalog still answers below.
        }

        var store = await RowsAsync(connection, HanaCatalog.TableStore, cancellationToken, table.Schema, table.Name);
        var columns = await ColumnRowsAsync(connection, table, cancellationToken);
        if (store.Count == 0 || columns.Count == 0)
        {
            throw new InvalidOperationException($"No definition was found for {table}.");
        }

        var indexes = await RowsAsync(connection, HanaCatalog.Indexes, cancellationToken, table.Schema, table.Name);
        var comment = CatalogValues.NonEmpty(await TextAsync(connection, HanaCatalog.TableComment, cancellationToken, table.Schema, table.Name));
        return HanaDdl.TableDefinition(table, CatalogValues.Flag(store[0][0]), columns, indexes, comment);
    }

    private Task<List<object?[]>> ColumnRowsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var schema = Owner(table.Schema);
        return RowsAsync(connection, HanaCatalog.Columns, cancellationToken, schema, table.Name, schema, table.Name);
    }

    private static InvalidOperationException Missing(DatabaseObject obj) => new($"No definition was found for {obj.Name}.");

    private string Owner(string? schema) =>
        !string.IsNullOrEmpty(schema) ? schema : _defaultSchema ?? throw new InvalidOperationException("Choose a SAP HANA schema first.");
}
