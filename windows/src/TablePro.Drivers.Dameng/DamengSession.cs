using System.Data.Common;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Odbc;

namespace TablePro.Drivers.Dameng;

/// <summary>
/// Dameng DM8 through its ODBC driver. DM8 speaks Oracle-compatible SQL, so the session uses Core's Oracle dialect and
/// PL/SQL blocks split at a lone slash. Schemas are the sidebar's level; the session opens on the Database field's
/// schema, or the login's own when it is empty.
/// </summary>
/// <remarks>
/// Core's Oracle dialect writes <c>:pN</c> markers, which ODBC cannot bind; <see cref="OdbcSession"/> rewrites them to
/// <c>?</c> for browse, count and save. A read-only profile sets the DM8 session read-only on every connection with
/// <c>SP_SET_SESSION_READONLY</c>, beyond the save refusal and the app's Safe Mode.
/// </remarks>
internal sealed class DamengSession
    : OdbcSession, ISchemaDdlProvider, IServerActivityProvider, IServerVariablesProvider, IUserListProvider
{
    private const string ExplainPrefix = "EXPLAIN PLAN FOR ";

    private readonly string[] _connectionSetup;
    private string? _defaultSchema;

    public DamengSession(ConnectionRequest request)
        : base(request, OracleDialect.Instance, DamengConnectionStringFactory.Driver, DamengConnectionStringFactory.Build(request))
    {
        _defaultSchema = string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim();
        _connectionSetup = Setup(_defaultSchema, request.Profile.IsReadOnly);
    }

    public override string? DefaultSchema => _defaultSchema;

    /// <summary>Whether the server reads a backslash in a literal as an escape, which the DDL's literals must follow.</summary>
    internal bool BackslashEscapes { get; private set; }

    public IReadOnlyList<string> CommonDataTypes => DamengDdl.CommonDataTypes;

    public string ProcessIdColumn => "SESS_ID";

    protected override string PingSql => DamengCatalog.Ping;

    protected override IReadOnlyList<string> ConnectionSetup => _connectionSetup;

    /// <summary>The statements every connection runs: the schema, then the read-only mode.</summary>
    internal static string[] Setup(string? schema, bool readOnly)
    {
        var statements = new List<string>(2);
        if (!string.IsNullOrEmpty(schema))
        {
            statements.Add("SET SCHEMA " + OracleDialect.Instance.QuoteIdentifier(schema));
        }

        if (readOnly)
        {
            statements.Add(DamengCatalog.ReadOnly);
        }

        return [.. statements];
    }

    protected override async Task OnConnectedAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        _defaultSchema ??= await TextAsync(connection, DamengCatalog.CurrentSchema, cancellationToken);
        CurrentDatabase = await TryTextAsync(connection, DamengCatalog.DatabaseName, cancellationToken) ?? CurrentDatabase;

        // Unknown keeps literals unescaped, which is what a server with BACKSLASH_ESCAPE off (the default) reads.
        BackslashEscapes = (await TryTextAsync(connection, DamengCatalog.BackslashProbe, cancellationToken))?.Trim() == "1";
    }

    /// <summary>
    /// Core's Oracle dialect asks for <c>EXPLAIN PLAN FOR</c> and DBMS_XPLAN, which DM8 lacks; DM8's own
    /// <c>EXPLAIN</c> returns the plan as text in one step. Only the exact pair the dialect wrote is replaced.
    /// </summary>
    internal override OdbcBatch PrepareBatch(IReadOnlyList<string> statements)
    {
        if (statements.Count == 2 && statements[0].StartsWith(ExplainPrefix, StringComparison.Ordinal))
        {
            var inner = statements[0][ExplainPrefix.Length..];
            if (OracleDialect.Instance.Explain(inner).SequenceEqual(statements, StringComparer.Ordinal))
            {
                return OdbcBatch.Unchanged(["EXPLAIN " + inner]);
            }
        }

        return OdbcBatch.Unchanged(statements);
    }

    /// <summary>The level above schemas is the instance's one database, which the switcher has nothing to switch to.</summary>
    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override async Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        var rows = await RowsAsync(connection, DamengCatalog.Schemas, cancellationToken);
        return DamengCatalog.UserSchemas(rows.Select(r => CatalogValues.Text(r[0]) ?? string.Empty), _defaultSchema);
    }

    protected override async Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var owner = Owner(schema);
        var rows = await RowsAsync(connection, DamengCatalog.Objects, cancellationToken, owner, owner, owner, owner);
        return rows.Select(r => DamengCatalog.MapObject(owner, r)).ToArray();
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var owner = Owner(table.Schema);
        var rows = await RowsAsync(connection, DamengCatalog.Columns, cancellationToken, owner, table.Name, owner, table.Name);
        var identity = await IdentityColumnsAsync(connection, owner, table.Name, cancellationToken);
        var columns = new ColumnInfo[rows.Count];
        for (var i = 0; i < columns.Length; i++)
        {
            columns[i] = DamengCatalog.MapColumn(rows[i], i, identity);
        }

        return columns;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        DamengCatalog.MapIndexes(await RowsAsync(connection, DamengCatalog.Indexes, cancellationToken, table.Name, Owner(table.Schema)));

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        DamengCatalog.MapForeignKeys(await RowsAsync(connection, DamengCatalog.ForeignKeys, cancellationToken, table.Name, Owner(table.Schema)));

    protected override async Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await RowsAsync(connection, DamengCatalog.TableTriggers, cancellationToken, Owner(table.Schema), table.Name);
        return rows.Select(DamengCatalog.MapTrigger).ToArray();
    }

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var name = obj.Name with { Schema = Owner(obj.Name.Schema) };
        var owner = name.Schema!;
        switch (obj.Kind)
        {
            case ObjectKind.Table:
                return await TableDefinitionAsync(connection, name, cancellationToken);
            case ObjectKind.View:
                return await TextAsync(connection, DamengCatalog.ViewText, cancellationToken, owner, name.Name) is { } text
                    ? DamengCatalog.ViewDefinition(name, text)
                    : throw Missing(obj);
            case ObjectKind.Procedure or ObjectKind.Function:
                var lines = await RowsAsync(connection, DamengCatalog.Source, cancellationToken, owner, name.Name, obj.Kind == ObjectKind.Procedure ? "PROCEDURE" : "FUNCTION");
                return lines.Count > 0
                    ? DamengCatalog.RoutineDefinition(lines.Select(r => CatalogValues.Text(r[0])))
                    : throw new InvalidOperationException($"Dameng returned no source for {obj.Name}; the login may lack the privilege to read it.");
            case ObjectKind.Sequence:
                var sequence = await RowsAsync(connection, DamengCatalog.Sequence, cancellationToken, owner, name.Name);
                return sequence.Count > 0 ? DamengDdl.SequenceDefinition(name, sequence[0]) : throw Missing(obj);
            case ObjectKind.Trigger:
                var trigger = await RowsAsync(connection, DamengCatalog.Trigger, cancellationToken, owner, name.Name);
                return trigger.Count > 0 && DamengCatalog.TriggerDefinition(trigger[0]) is { Length: > 0 } definition ? definition : throw Missing(obj);
            default:
                throw new NotSupportedException($"Dameng has no definition for a {obj.Kind}.");
        }
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) =>
        DamengDdl.Build(table.Schema is null ? table with { Schema = _defaultSchema } : table, change, BackslashEscapes);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(DamengCatalog.Activity, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken) =>
        RunAsync(DamengCatalog.Kill, cancellationToken, DamengDdl.SessionId(processId));

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) => ReadResultAsync(DamengCatalog.Variables, cancellationToken);

    /// <summary>DBA_USERS needs a DBA grant; ALL_USERS is what any login may read.</summary>
    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) =>
        ReadFirstAsync(DamengCatalog.DbaUsers, DamengCatalog.AllUsers, cancellationToken);

    /// <summary>SP_TABLEDEF is DM8's own DDL; without it the statement is rebuilt from the dictionary, as on macOS.</summary>
    private async Task<string> TableDefinitionAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        try
        {
            var lines = await RowsAsync(connection, DamengCatalog.TableDefinition, cancellationToken, table.Schema, table.Name);
            var text = string.Concat(lines.Select(r => CatalogValues.Text(r[0]))).Trim();
            if (text.Length > 0)
            {
                return text;
            }
        }
        catch (OdbcDriverException)
        {
            // An older server, or a login without the privilege to run it: the dictionary still answers below.
        }

        var columns = await LoadColumnsAsync(connection, table, cancellationToken);
        if (columns.Count == 0)
        {
            throw new InvalidOperationException($"No definition was found for {table}.");
        }

        var indexes = DamengDdl.IndexStatements(table, await RowsAsync(connection, DamengCatalog.IndexDefinitions, cancellationToken, table.Name, table.Schema));
        return DamengDdl.TableDefinition(table, columns, indexes, BackslashEscapes);
    }

    private static async Task<IReadOnlySet<string>> IdentityColumnsAsync(DbConnection connection, string owner, string table, CancellationToken cancellationToken)
    {
        try
        {
            var rows = await RowsAsync(connection, DamengCatalog.IdentityColumns, cancellationToken, owner, table);
            return rows.Select(r => CatalogValues.Text(r[0]) ?? string.Empty).ToHashSet(StringComparer.Ordinal);
        }
        catch (OdbcDriverException)
        {
            // The system tables can be closed to a login that may read the dictionary views; columns then show no identity.
            return new HashSet<string>(StringComparer.Ordinal);
        }
    }

    private static InvalidOperationException Missing(DatabaseObject obj) => new($"No definition was found for {obj.Name}.");

    private string Owner(string? schema) =>
        !string.IsNullOrEmpty(schema)
            ? schema
            : _defaultSchema ?? Profile.Username?.Trim().ToUpperInvariant() ?? throw new InvalidOperationException("No schema was given and the login names none.");
}
