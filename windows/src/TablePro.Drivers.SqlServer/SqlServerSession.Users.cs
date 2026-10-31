using System.Data.Common;
using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Principals;

namespace TablePro.Drivers.SqlServer;

public sealed partial class SqlServerSession : IUserAdministration
{
    private static readonly UserAdministrationFeatures SqlServerUserFeatures = new(
        RoleMembership: true,
        ScopeSearch: true,
        RestrictsBrowsingToCurrentDatabase: true,
        ConnectionLimit: false,
        RoleLogin: false,
        Transaction: new PrincipalTransaction("BEGIN TRANSACTION", "COMMIT TRANSACTION", "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"));

    // The statements need to know what each name is, so the directory of the last load is kept for building them.
    private volatile SqlServerPrincipalDirectory? _principalDirectory;
    private volatile PrivilegeCatalog? _privilegeCatalog;

    public UserAdministrationFeatures? Features => SqlServerUserFeatures;

    public Task<PrincipalSnapshot> LoadPrincipalsAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var session = await QueryAsync(connection, SqlServerUserCatalog.Session, static r => (Database: NullableString(r, 0) ?? string.Empty, Login: NullableString(r, 1)), ct);
                var (database, login) = session[0];
                var directory = await LoadDirectoryAsync(connection, database, ct);
                _principalDirectory = directory;

                var principals = directory.Entries
                    .Select(e => new PrincipalInfo(new PrincipalRef(e.Name), e.IsRole, !e.IsRole && e.IsEnabled, [], e.MemberOf))
                    .ToArray();
                var catalog = await PrivilegeCatalogAsync(connection, ct);
                var databases = await LoadDatabasesAsync(connection, ct);
                return new PrincipalSnapshot(principals, catalog, databases, database, login is null ? null : new PrincipalRef(login));
            },
            cancellationToken);

    public Task<IReadOnlyList<PrincipalGrant>> LoadGrantsAsync(PrincipalRef principal, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrincipalGrant>>(
            async (connection, ct) =>
            {
                var directory = await DirectoryAsync(connection, ct);
                var grants = new List<PrincipalGrant>();
                switch (directory.Entry(principal.Name))
                {
                    case { Kind: SqlServerPrincipalKind.Login } entry:
                        grants.AddRange(await ServerGrantsAsync(connection, principal.Name, ct));
                        if (entry.User is { } user)
                        {
                            grants.AddRange(await DatabaseGrantsAsync(connection, directory.Database, user, ct));
                        }

                        break;
                    case { Kind: SqlServerPrincipalKind.ServerRole }:
                        grants.AddRange(await ServerGrantsAsync(connection, principal.Name, ct));
                        break;
                    case { }:
                        grants.AddRange(await DatabaseGrantsAsync(connection, directory.Database, principal.Name, ct));
                        break;
                }

                return grants;
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> LoadChildScopesAsync(PrivilegeScope scope, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrivilegeScope>>(
            async (connection, ct) =>
            {
                var database = (await DirectoryAsync(connection, ct)).Database;
                if (scope.Database != database)
                {
                    return [];
                }

                return scope.Level switch
                {
                    PrivilegeLevel.Database => await QueryAsync(connection, SqlServerUserCatalog.Schemas(database), r => PrivilegeScope.ForSchema(database, r.GetString(0)), ct),
                    PrivilegeLevel.Schema => await QueryAsync(
                        connection,
                        SqlServerUserCatalog.Objects(database),
                        r => PrivilegeScope.ForTable(database, scope.Schema, r.GetString(0)),
                        ct,
                        ("@schema", scope.Schema)),
                    PrivilegeLevel.Table when scope.Schema is not null => await QueryAsync(
                        connection,
                        SqlServerUserCatalog.Columns(database),
                        r => PrivilegeScope.ForColumn(database, scope.Schema, scope.Table!, r.GetString(0)),
                        ct,
                        ("@schema", scope.Schema),
                        ("@object", scope.Table)),
                    _ => [],
                };
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> SearchScopesAsync(string text, int limit, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var database = (await DirectoryAsync(connection, ct)).Database;
                return await QueryAsync(
                    connection,
                    SqlServerUserCatalog.SearchObjects(database),
                    r => PrivilegeScope.ForTable(database, r.GetString(0), r.GetString(1)),
                    ct,
                    ("@limit", Math.Max(1, limit)),
                    ("@pattern", SqlServerUserCatalog.ContainsPattern(text)));
            },
            cancellationToken);

    // Schema ownership blocks DROP USER too, but the server's error names the schema, and nothing is reassigned here.
    public Task<bool> OwnsObjectsAsync(PrincipalRef principal, CancellationToken cancellationToken) => Task.FromResult(false);

    // A permission on the database or a schema covers every object under it; server permissions have names of their own.
    public bool Cascades(PrivilegeScope ancestor, PrivilegeScope descendant) => ancestor.Level != PrivilegeLevel.Server && ancestor.Contains(descendant);

    public IReadOnlyList<PrincipalStatement> BuildStatements(IReadOnlyList<PrincipalChange> changes) =>
        PrincipalScript.Build(new SqlServerUserSql(_principalDirectory), changes);

    private async Task<SqlServerPrincipalDirectory> DirectoryAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        if (_principalDirectory is { } cached)
        {
            return cached;
        }

        var database = await ScalarAsync(connection, "SELECT DB_NAME()", cancellationToken) as string ?? string.Empty;
        var directory = await LoadDirectoryAsync(connection, database, cancellationToken);
        _principalDirectory = directory;
        return directory;
    }

    private static async Task<SqlServerPrincipalDirectory> LoadDirectoryAsync(DbConnection connection, string database, CancellationToken cancellationToken)
    {
        var logins = await QueryAsync(connection, SqlServerUserCatalog.Logins(database), static r => new SqlServerLoginRow(r.GetString(0), r.GetInt32(1) != 0, NullableString(r, 2)), cancellationToken);
        var serverRoles = await QueryAsync(connection, SqlServerUserCatalog.ServerRoles, static r => r.GetString(0), cancellationToken);
        var databasePrincipals = await QueryAsync(
            connection,
            SqlServerUserCatalog.DatabasePrincipals(database),
            static r => new SqlServerDatabasePrincipalRow(r.GetString(0), r.GetString(1).Trim() == "R", r.GetInt32(2) != 0),
            cancellationToken);
        var serverMembers = await QueryAsync(connection, SqlServerUserCatalog.ServerRoleMembers, static r => new SqlServerMembershipRow(r.GetString(0), r.GetString(1)), cancellationToken);
        var databaseMembers = await QueryAsync(
            connection,
            SqlServerUserCatalog.DatabaseRoleMembers(database),
            static r => new SqlServerMembershipRow(r.GetString(0), r.GetString(1)),
            cancellationToken);
        return new SqlServerPrincipalDirectory(database, logins, serverRoles, databasePrincipals, serverMembers, databaseMembers);
    }

    private static Task<IReadOnlyList<PrincipalGrant>> ServerGrantsAsync(DbConnection connection, string grantee, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            SqlServerUserCatalog.ServerPermissions,
            static r => new PrincipalGrant(r.GetString(0), PrivilegeScope.Server, SqlServerUserCatalog.IsGrantable(NullableString(r, 1))),
            cancellationToken,
            ("@grantee", grantee));

    private static async Task<IEnumerable<PrincipalGrant>> DatabaseGrantsAsync(DbConnection connection, string database, string grantee, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            SqlServerUserCatalog.DatabasePermissions(database),
            r => SqlServerUserCatalog.DatabaseGrant(
                database,
                Convert.ToInt32(r.GetValue(0), CultureInfo.InvariantCulture),
                r.GetString(1),
                NullableString(r, 2),
                NullableString(r, 3),
                NullableString(r, 4),
                NullableString(r, 5)),
            cancellationToken,
            ("@grantee", grantee));
        return rows.OfType<PrincipalGrant>();
    }

    private async Task<PrivilegeCatalog> PrivilegeCatalogAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        if (_privilegeCatalog is { } cached)
        {
            return cached;
        }

        var rows = await QueryAsync(connection, SqlServerUserCatalog.BuiltinPermissions, static r => (r.GetString(0), r.GetString(1)), cancellationToken);
        var catalog = SqlServerUserCatalog.BuildCatalog(rows);
        _privilegeCatalog = catalog;
        return catalog;
    }
}
