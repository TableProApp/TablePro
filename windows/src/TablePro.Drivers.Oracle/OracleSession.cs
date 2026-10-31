using System.Data.Common;
using System.Globalization;
using System.Text;
using Oracle.ManagedDataAccess.Client;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// Oracle through ODP.NET's managed driver, which speaks the protocol itself and needs no Instant Client. Schemas are
/// the users that own objects; the sidebar opens on the login's own.
/// </summary>
/// <remarks>
/// Core's browse, count and save run unchanged: ODP.NET binds by position unless told otherwise, and Core writes each
/// <c>:pN</c> placeholder once, in the order it adds the parameters. The catalog reads here bind by name and fetch
/// LONG columns whole, since DATA_DEFAULT, TRIGGER_BODY and index expressions are LONGs ODP.NET otherwise returns empty.
/// It declares <see cref="IDatabaseSession"/> again only so its own <see cref="PingAsync"/> replaces the base class's
/// <c>SELECT 1</c>, which Oracle before 23ai refuses without <c>FROM DUAL</c>.
/// </remarks>
public sealed partial class OracleSession
    : AdoNetSession, IDatabaseSession, ISchemaDdlProvider, IServerActivityProvider, IServerVariablesProvider, IUserListProvider
{
    private const string PingSql = "SELECT 1 FROM DUAL";

    private readonly string _connectionString;
    private readonly string? _defaultSchema;
    private readonly string[] _startupStatements;

    public OracleSession(ConnectionRequest request)
        : base(request, OracleDialect.Instance)
    {
        _connectionString = OracleConnectionStringFactory.Build(request);
        _defaultSchema = OracleConnectionStringFactory.DefaultSchema(request.Profile.Username);
        _startupStatements = string.IsNullOrWhiteSpace(request.Profile.StartupCommands)
            ? []
            : OracleScript.Split(request.Profile.StartupCommands).Select(s => s.Text).ToArray();
    }

    public override string? DefaultSchema => _defaultSchema;

    public IReadOnlyList<string> CommonDataTypes => OracleDdl.CommonDataTypes;

    public string ProcessIdColumn => "SESSION_ID";

    // A NUMBER can hold more digits than decimal; truncating them beats failing the whole result with a cast error.
    protected override DbConnection CreateConnection() =>
        new OracleConnection(_connectionString) { SuppressGetDecimalInvalidCastException = true };

    /// <summary>
    /// A pooled connection keeps its session, but nothing says whether this one is fresh, so the settings run on every
    /// open as one statement.
    /// </summary>
    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        await ExecuteAsync(connection, OracleCatalog.SessionSettings, cancellationToken);
        foreach (var statement in _startupStatements)
        {
            await ExecuteAsync(connection, statement, cancellationToken);
        }
    }

    protected override void AttachMessages(DbConnection connection, Action<string> onMessage) =>
        ((OracleConnection)connection).InfoMessage += (_, e) => onMessage(e.Message);

    /// <summary>One connection reaches one database: the service it dialled.</summary>
    protected override async Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrEmpty(CurrentDatabase))
        {
            return [CurrentDatabase];
        }

        return await ScalarAsync(connection, OracleCatalog.ServiceName, cancellationToken) is string service ? [service] : [];
    }

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        OracleQueryAsync(connection, OracleCatalog.Schemas, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var owner = Owner(schema);
        return OracleQueryAsync(connection, OracleCatalog.Objects, r => MapObject(owner, r), cancellationToken, ("owner", owner));
    }

    private static DatabaseObject MapObject(string owner, DbDataReader r)
    {
        var name = new ObjectName(owner, r.GetString(0));
        var comment = NullableString(r, 3);
        return r.GetString(1) switch
        {
            "TABLE" => new DatabaseObject(name, ObjectKind.Table, Int64(r, 2), comment),
            "VIEW" => new DatabaseObject(name, ObjectKind.View, null, comment),
            "MATERIALIZED VIEW" => new DatabaseObject(name, ObjectKind.MaterializedView),
            "PACKAGE" => new DatabaseObject(name, ObjectKind.Procedure, null, OracleDdl.PackageMarker),
            "PROCEDURE" => new DatabaseObject(name, ObjectKind.Procedure),
            "FUNCTION" => new DatabaseObject(name, ObjectKind.Function),
            "SEQUENCE" => new DatabaseObject(name, ObjectKind.Sequence),
            _ => new DatabaseObject(name, ObjectKind.View, null, SynonymComment(NullableString(r, 4), NullableString(r, 5))),
        };
    }

    internal static string SynonymComment(string? owner, string? target) =>
        string.Concat(OracleDdl.SynonymPrefix, string.IsNullOrEmpty(owner) ? string.Empty : owner + ".", target ?? "?");

    protected override Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var ordinal = 0;
        return OracleQueryAsync(
            connection,
            OracleCatalog.Columns,
            r =>
            {
                var identity = NullableString(r, 8) == "YES";
                var type = OracleDdl.FormatType(r.GetString(1), Int32(r, 2) ?? 0, Int32(r, 3) ?? 0, NullableString(r, 4), Int32(r, 5), Int32(r, 6));
                var defaultValue = NullableString(r, 11)?.Trim();
                return new ColumnInfo(
                    r.GetString(0),
                    type,
                    NullableString(r, 7) != "N",

                    // An identity's default is the sequence behind it, which no one typed.
                    identity || string.IsNullOrEmpty(defaultValue) ? null : defaultValue,
                    Truthy(r, 10),
                    identity,
                    ordinal++,
                    NullableString(r, 9));
            },
            cancellationToken,
            Bind(table));
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await OracleQueryAsync(
            connection,
            OracleCatalog.Indexes,
            static r => (Name: r.GetString(0), Unique: NullableString(r, 1) == "UNIQUE", Type: NullableString(r, 2), Column: NullableString(r, 6)?.Trim() ?? r.GetString(3),
                Descending: NullableString(r, 4) == "DESC", Primary: Truthy(r, 5)),
            cancellationToken,
            Bind(table));

        var indexes = new List<IndexInfo>();
        foreach (var group in rows.GroupBy(r => r.Name, StringComparer.Ordinal))
        {
            var first = group.First();
            var columns = group.Select(r => r.Descending ? r.Column + " DESC" : r.Column).ToArray();
            indexes.Add(new IndexInfo(first.Name, columns, first.Unique, first.Primary, first.Type));
        }

        return indexes;
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await OracleQueryAsync(
            connection,
            OracleCatalog.ForeignKeys,
            static r => (Name: r.GetString(0), Column: r.GetString(1), ReferencedSchema: r.GetString(2), ReferencedTable: r.GetString(3),
                ReferencedColumn: r.GetString(4), OnDelete: NullableString(r, 5) ?? "NO ACTION"),
            cancellationToken,
            Bind(table));

        // Oracle has no ON UPDATE action, so every key reports NO ACTION for it.
        return rows.GroupBy(r => r.Name, StringComparer.Ordinal)
            .Select(g =>
            {
                var first = g.First();
                return new ForeignKeyInfo(
                    first.Name,
                    g.Select(r => r.Column).ToArray(),
                    new ObjectName(first.ReferencedSchema, first.ReferencedTable),
                    g.Select(r => r.ReferencedColumn).ToArray(),
                    "NO ACTION",
                    first.OnDelete);
            })
            .ToArray();
    }

    protected override Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        OracleQueryAsync(
            connection,
            OracleCatalog.Triggers,
            static r =>
            {
                var name = r.GetString(0);
                return new TriggerInfo(
                    name,
                    OracleDdl.Timing(NullableString(r, 1) ?? string.Empty),
                    NullableString(r, 2) ?? string.Empty,
                    OracleDdl.TriggerDefinition(name, NullableString(r, 3), NullableString(r, 4), NullableString(r, 5), NullableString(r, 6), NullableString(r, 7)));
            },
            cancellationToken,
            Bind(table));

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var owner = Owner(obj.Name.Schema);
        var name = obj.Name.Name;
        var type = await ObjectTypeAsync(connection, obj, owner, cancellationToken);
        try
        {
            await ExecuteAsync(connection, OracleCatalog.MetadataTransforms, cancellationToken);
            var ddl = await OracleQueryAsync(
                connection,
                OracleCatalog.Ddl,
                static r => NullableString(r, 0),
                cancellationToken,
                ("objtype", OracleDdl.MetadataType(type)),
                ("tbl", name),
                ("owner", owner));
            if (ddl.Count > 0 && !string.IsNullOrWhiteSpace(ddl[0]))
            {
                return ddl[0]!.Trim();
            }
        }
        catch (OracleException) when (type is "VIEW" or "PROCEDURE" or "FUNCTION" or "PACKAGE" or "TRIGGER")
        {
            // ORA-31603 without SELECT_CATALOG_ROLE for another schema; the source views still answer below.
        }

        return await SourceDefinitionAsync(connection, obj, owner, type, cancellationToken);
    }

    public new Task PingAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync((connection, ct) => ScalarAsync(connection, PingSql, ct), cancellationToken);

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) =>
        OracleDdl.Build(table.Schema is null ? table with { Schema = _defaultSchema } : table, change);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(OracleCatalog.Activity, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        var sql = OracleDdl.Kill(processId);
        return WithConnectionAsync(
            async (connection, ct) =>
            {
                await ExecuteAsync(connection, sql, ct);
                return 0;
            },
            cancellationToken);
    }

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) => ReadResultAsync(OracleCatalog.Variables, cancellationToken);

    /// <summary>DBA_USERS needs a DBA grant; ALL_USERS is what any login may read.</summary>
    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                try
                {
                    return await ReadAsync(connection, OracleCatalog.DbaUsers, ct);
                }
                catch (OracleException)
                {
                    return await ReadAsync(connection, OracleCatalog.AllUsers, ct);
                }
            },
            cancellationToken);

    /// <summary>The dictionary's own object type, since a view may be a synonym and a procedure a package.</summary>
    private static async Task<string> ObjectTypeAsync(DbConnection connection, DatabaseObject obj, string owner, CancellationToken cancellationToken)
    {
        string[] candidates = obj.Kind switch
        {
            ObjectKind.Table => ["TABLE"],
            ObjectKind.View => ["VIEW", "SYNONYM"],
            ObjectKind.MaterializedView => ["MATERIALIZED VIEW"],
            ObjectKind.Procedure => ["PROCEDURE", "PACKAGE"],
            ObjectKind.Function => ["FUNCTION"],
            ObjectKind.Sequence => ["SEQUENCE"],
            ObjectKind.Trigger => ["TRIGGER"],
            _ => throw new NotSupportedException(CoreStrings.Format("Driver/EngineHasNoDefinitionFor", "Oracle", obj.Name)),
        };

        if (candidates.Length == 1)
        {
            return candidates[0];
        }

        var types = await OracleQueryAsync(connection, OracleCatalog.ObjectTypes, static r => r.GetString(0), cancellationToken, ("owner", owner), ("tbl", obj.Name.Name));
        return candidates.FirstOrDefault(types.Contains) ?? throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
    }

    private static async Task<string> SourceDefinitionAsync(DbConnection connection, DatabaseObject obj, string owner, string type, CancellationToken cancellationToken)
    {
        if (type == "VIEW")
        {
            var text = await OracleQueryAsync(connection, OracleCatalog.ViewText, static r => NullableString(r, 0), cancellationToken, ("owner", owner), ("tbl", obj.Name.Name));
            return text.Count > 0 && text[0] is { } body
                ? string.Concat("CREATE OR REPLACE VIEW ", OracleDialect.Instance.Qualify(obj.Name with { Schema = owner }), " AS\n", body.Trim())
                : throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
        }

        var sql = new StringBuilder();
        foreach (var part in type == "PACKAGE" ? new[] { "PACKAGE", "PACKAGE BODY" } : [type])
        {
            var lines = await OracleQueryAsync(connection, OracleCatalog.Source, static r => NullableString(r, 0) ?? string.Empty, cancellationToken, ("owner", owner), ("tbl", obj.Name.Name), ("objtype", part));
            if (lines.Count == 0)
            {
                continue;
            }

            if (sql.Length > 0)
            {
                sql.Append("\n/\n\n");
            }

            sql.Append("CREATE OR REPLACE ").AppendJoin(string.Empty, lines);
        }

        return sql.Length > 0 ? sql.ToString().TrimEnd() : throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
    }

    private Task<ResultSet> ReadResultAsync(string sql, CancellationToken cancellationToken) =>
        WithConnectionAsync((connection, ct) => ReadAsync(connection, sql, ct), cancellationToken);

    private static async Task<ResultSet> ReadAsync(DbConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var command = Prepare(connection, sql, []);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await ResultSetReader.ReadAsync(reader, int.MaxValue, cancellationToken);
    }

    private static async Task ExecuteAsync(DbConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var command = Prepare(connection, sql, []);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<IReadOnlyList<T>> OracleQueryAsync<T>(
        DbConnection connection,
        string sql,
        Func<DbDataReader, T> map,
        CancellationToken cancellationToken,
        params (string Name, object? Value)[] parameters)
    {
        await using var command = Prepare(connection, sql, parameters);
        var list = new List<T>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(map(reader));
        }

        return list;
    }

    private static OracleCommand Prepare(DbConnection connection, string sql, (string Name, object? Value)[] parameters)
    {
        var command = ((OracleConnection)connection).CreateCommand();
        command.CommandText = sql;
        command.BindByName = true;
        command.InitialLONGFetchSize = -1;
        foreach (var (name, value) in parameters)
        {
            command.Parameters.Add(name, value ?? DBNull.Value);
        }

        return command;
    }

    private (string, object?)[] Bind(ObjectName table) => [("owner", Owner(table.Schema)), ("tbl", table.Name)];

    private string Owner(string? schema) =>
        !string.IsNullOrEmpty(schema) ? schema : _defaultSchema ?? throw new InvalidOperationException(CoreStrings.Get("Driver/NoSchemaGiven"));

    private static long? Int64(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal), CultureInfo.InvariantCulture);

    private static int? Int32(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal), CultureInfo.InvariantCulture);
}
