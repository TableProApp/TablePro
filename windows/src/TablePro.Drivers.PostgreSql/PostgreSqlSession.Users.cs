using System.Data.Common;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Principals;

namespace TablePro.Drivers.PostgreSql;

public sealed partial class PostgreSqlSession : IUserAdministration
{
    private static readonly UserAdministrationFeatures PostgreSqlUserFeatures = new(
        RoleMembership: true,
        OwnedObjectReassignment: true,
        ScopeSearch: true,
        RestrictsBrowsingToCurrentDatabase: true,
        Rename: true,
        Transaction: new PrincipalTransaction("BEGIN", "COMMIT", "ROLLBACK"));

    // Replaced on each load with one that knows the server version, so BYPASSRLS is never sent to a server before 9.5.
    private volatile PostgreSqlUserSql _userSql = new();

    // CockroachDB has no aclexplode or pg_shdepend, and Redshift has users and groups instead of roles, so the editor
    // would only fail on them; they keep the read-only Users list.
    public UserAdministrationFeatures? Features =>
        Profile.Engine is DatabaseEngine.PostgreSql or DatabaseEngine.PGlite ? PostgreSqlUserFeatures : null;

    public Task<PrincipalSnapshot> LoadPrincipalsAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var session = await QueryAsync(connection, PostgreSqlUserCatalog.Session, static r => (Version: r.GetInt32(0), User: r.GetString(1), Database: r.GetString(2)), ct);
                var (version, user, database) = session[0];
                var userSql = new PostgreSqlUserSql(supportsBypassRls: version >= 90500);
                _userSql = userSql;

                var principals = await QueryAsync(connection, PostgreSqlUserCatalog.Principals(version >= 90500), r => ReadPrincipal(r, userSql), ct);
                var databases = await LoadDatabasesAsync(connection, ct);
                return new PrincipalSnapshot(principals, PostgreSqlUserSql.Catalog, databases, database, new PrincipalRef(user));
            },
            cancellationToken);

    public Task<IReadOnlyList<PrincipalGrant>> LoadGrantsAsync(PrincipalRef principal, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrincipalGrant>>(
            async (connection, ct) =>
            {
                var database = await CurrentDatabaseNameAsync(connection, ct);
                var role = ("@role", (object?)principal.Name);
                var grants = new List<PrincipalGrant>();
                grants.AddRange(await QueryAsync(
                    connection,
                    PostgreSqlUserCatalog.DatabaseGrants,
                    static r => new PrincipalGrant(r.GetString(1), PrivilegeScope.ForDatabase(r.GetString(0)), r.GetBoolean(2)),
                    ct,
                    role));
                grants.AddRange(await QueryAsync(
                    connection,
                    PostgreSqlUserCatalog.SchemaGrants,
                    r => new PrincipalGrant(r.GetString(1), PrivilegeScope.ForSchema(database, r.GetString(0)), r.GetBoolean(2)),
                    ct,
                    role));
                grants.AddRange(await QueryAsync(
                    connection,
                    PostgreSqlUserCatalog.TableGrants,
                    r => new PrincipalGrant(r.GetString(2), PrivilegeScope.ForTable(database, r.GetString(0), r.GetString(1)), r.GetBoolean(3)),
                    ct,
                    role));
                grants.AddRange(await QueryAsync(
                    connection,
                    PostgreSqlUserCatalog.ColumnGrants,
                    r => new PrincipalGrant(r.GetString(3), PrivilegeScope.ForColumn(database, r.GetString(0), r.GetString(1), r.GetString(2)), r.GetBoolean(4)),
                    ct,
                    role));
                return grants;
            },
            cancellationToken);

    // A PostgreSQL connection sees one database's catalog, so schemas and below are read only for the connected one.
    public Task<IReadOnlyList<PrivilegeScope>> LoadChildScopesAsync(PrivilegeScope scope, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrivilegeScope>>(
            async (connection, ct) =>
            {
                var database = await CurrentDatabaseNameAsync(connection, ct);
                if (scope.Database != database)
                {
                    return [];
                }

                return scope.Level switch
                {
                    PrivilegeLevel.Database => await QueryAsync(connection, PostgreSqlUserCatalog.Schemas, r => PrivilegeScope.ForSchema(database, r.GetString(0)), ct),
                    PrivilegeLevel.Schema => await QueryAsync(
                        connection,
                        PostgreSqlUserCatalog.Tables,
                        r => PrivilegeScope.ForTable(database, scope.Schema, r.GetString(0)),
                        ct,
                        ("@schema", scope.Schema)),
                    PrivilegeLevel.Table when scope.Schema is not null => await QueryAsync(
                        connection,
                        PostgreSqlUserCatalog.Columns,
                        r => PrivilegeScope.ForColumn(database, scope.Schema, scope.Table!, r.GetString(0)),
                        ct,
                        ("@schema", scope.Schema),
                        ("@table", scope.Table)),
                    _ => [],
                };
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> SearchScopesAsync(string text, int limit, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var database = await CurrentDatabaseNameAsync(connection, ct);
                return await QueryAsync(
                    connection,
                    PostgreSqlUserCatalog.SearchObjects,
                    r => PrivilegeScope.ForTable(database, r.GetString(0), r.GetString(1)),
                    ct,
                    ("@pattern", PostgreSqlUserCatalog.ContainsPattern(text)),
                    ("@limit", Math.Max(1, limit)));
            },
            cancellationToken);

    public Task<bool> OwnsObjectsAsync(PrincipalRef principal, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) => await ScalarAsync(connection, PostgreSqlUserCatalog.OwnsObjects, ct, ("@role", principal.Name)) is true,
            cancellationToken);

    // Only a table grant reaches down, to its columns; a schema or database privilege such as USAGE or CONNECT is a
    // different privilege from anything granted on the objects inside it.
    public bool Cascades(PrivilegeScope ancestor, PrivilegeScope descendant) =>
        ancestor.Level == PrivilegeLevel.Table && descendant.Level == PrivilegeLevel.Column && ancestor.Contains(descendant);

    public IReadOnlyList<PrincipalStatement> BuildStatements(IReadOnlyList<PrincipalChange> changes) => PrincipalScript.Build(_userSql, changes);

    private static async Task<string> CurrentDatabaseNameAsync(DbConnection connection, CancellationToken cancellationToken) =>
        await ScalarAsync(connection, "SELECT current_database()::text", cancellationToken) as string ?? string.Empty;

    private static PrincipalInfo ReadPrincipal(DbDataReader reader, PostgreSqlUserSql userSql)
    {
        var canLogin = reader.GetBoolean(1);
        var attributes = new List<PrincipalAttribute>();
        foreach (var attribute in userSql.Attributes)
        {
            var ordinal = attribute.Keyword switch
            {
                "SUPERUSER" => 2,
                "CREATEDB" => 3,
                "CREATEROLE" => 4,
                "REPLICATION" => 5,
                "BYPASSRLS" => 6,
                _ => 7,
            };
            attributes.Add(new PrincipalAttribute(attribute.Keyword, attribute.Label, reader.GetBoolean(ordinal)));
        }

        var limit = reader.GetInt32(8);
        return new PrincipalInfo(
            new PrincipalRef(reader.GetString(0)),
            IsRole: !canLogin,
            CanLogin: canLogin,
            attributes,
            reader.IsDBNull(10) ? [] : reader.GetFieldValue<string[]>(10),
            limit < 0 ? null : limit,
            reader.IsDBNull(9) ? null : reader.GetString(9));
    }
}
