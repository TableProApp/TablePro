using System.Data.Common;
using Oracle.ManagedDataAccess.Client;
using TablePro.Core.Drivers;
using TablePro.Core.Principals;

namespace TablePro.Drivers.Oracle;

public sealed partial class OracleSession : IUserAdministration
{
    // DDL commits on its own in Oracle, so an apply has no transaction to roll back; roles never log in.
    private static readonly UserAdministrationFeatures OracleUserFeatures = new(
        RoleMembership: true,
        ScopeSearch: true,
        ConnectionLimit: false,
        RoleLogin: false);

    private const int TableOrViewDoesNotExist = 942;

    // Probed once per session: an account that cannot read DBA_USERS reads the ALL_ and USER_ views instead.
    private OracleDictionaryAccess? _dictionaryAccess;

    // DROP USER and DROP ROLE are different statements, so the role names of the last load are kept for building them.
    private volatile IReadOnlySet<string> _roleNames = new HashSet<string>(StringComparer.Ordinal);
    private volatile PrivilegeCatalog? _privilegeCatalog;

    public UserAdministrationFeatures? Features => OracleUserFeatures;

    public Task<PrincipalSnapshot> LoadPrincipalsAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var access = await DictionaryAccessAsync(connection, ct);
                var users = await OracleQueryAsync(connection, OracleUserCatalog.Users(access), static r => (r.GetString(0), OracleUserCatalog.IsLocked(NullableString(r, 1))), ct);
                var roles = await OracleQueryAsync(connection, OracleUserCatalog.Roles(access), static r => r.GetString(0), ct);
                var grants = await OracleQueryAsync(connection, OracleUserCatalog.RoleGrants(access), static r => (r.GetString(0), r.GetString(1)), ct);
                _roleNames = roles.ToHashSet(StringComparer.Ordinal);

                var catalog = _privilegeCatalog ??= OracleUserCatalog.Catalog(
                    await OracleQueryAsync(connection, OracleUserCatalog.SystemPrivilegeMap, static r => r.GetString(0), ct));
                var schemas = await LoadSchemasAsync(connection, ct);
                var current = await ScalarAsync(connection, OracleUserCatalog.CurrentUser, ct) as string;
                return new PrincipalSnapshot(
                    OracleUserCatalog.Principals(users, roles, grants),
                    catalog,
                    schemas,
                    current,
                    current is null ? null : new PrincipalRef(current));
            },
            cancellationToken);

    public Task<IReadOnlyList<PrincipalGrant>> LoadGrantsAsync(PrincipalRef principal, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrincipalGrant>>(
            async (connection, ct) =>
            {
                var access = await DictionaryAccessAsync(connection, ct);
                var grantee = ("grantee", (object?)principal.Name);
                var system = await OracleQueryAsync(
                    connection,
                    OracleUserCatalog.SystemPrivileges(access),
                    static r => new PrincipalGrant(r.GetString(0), PrivilegeScope.Server, OracleUserCatalog.IsYes(NullableString(r, 1))),
                    ct,
                    grantee);
                var objects = await OracleQueryAsync(
                    connection,
                    OracleUserCatalog.ObjectPrivileges(access),
                    static r => new PrincipalGrant(r.GetString(2), PrivilegeScope.ForTable(r.GetString(0), null, r.GetString(1)), OracleUserCatalog.IsYes(NullableString(r, 3))),
                    ct,
                    grantee);
                var columns = await OracleQueryAsync(
                    connection,
                    OracleUserCatalog.ColumnPrivileges(access),
                    static r => new PrincipalGrant(
                        r.GetString(3),
                        PrivilegeScope.ForColumn(r.GetString(0), null, r.GetString(1), r.GetString(2)),
                        OracleUserCatalog.IsYes(NullableString(r, 4))),
                    ct,
                    grantee);
                return [.. system, .. objects, .. columns];
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> LoadChildScopesAsync(PrivilegeScope scope, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrivilegeScope>>(
            async (connection, ct) => scope.Level switch
            {
                PrivilegeLevel.Database => await OracleQueryAsync(
                    connection,
                    OracleUserCatalog.Objects,
                    r => PrivilegeScope.ForTable(scope.Database!, null, r.GetString(0)),
                    ct,
                    ("owner", scope.Database)),
                PrivilegeLevel.Table => await OracleQueryAsync(
                    connection,
                    OracleUserCatalog.Columns,
                    r => PrivilegeScope.ForColumn(scope.Database!, null, scope.Table!, r.GetString(0)),
                    ct,
                    ("owner", scope.Database),
                    ("tbl", scope.Table)),
                _ => [],
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> SearchScopesAsync(string text, int limit, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            (connection, ct) => OracleQueryAsync(
                connection,
                OracleUserCatalog.SearchObjects,
                static r => PrivilegeScope.ForTable(r.GetString(0), null, r.GetString(1)),
                ct,
                ("pattern", OracleUserCatalog.ContainsPattern(text)),
                ("limit", Math.Max(1, limit))),
            cancellationToken);

    // DROP USER without CASCADE refuses a user who owns objects, and the server's error says so; nothing is reassigned.
    public Task<bool> OwnsObjectsAsync(PrincipalRef principal, CancellationToken cancellationToken) => Task.FromResult(false);

    // A table privilege covers its columns; a system privilege such as SELECT ANY TABLE has a name of its own.
    public bool Cascades(PrivilegeScope ancestor, PrivilegeScope descendant) =>
        ancestor.Level == PrivilegeLevel.Table && descendant.Level == PrivilegeLevel.Column && ancestor.Contains(descendant);

    public IReadOnlyList<PrincipalStatement> BuildStatements(IReadOnlyList<PrincipalChange> changes) =>
        PrincipalScript.Build(new OracleUserSql(_roleNames), changes);

    private async Task<OracleDictionaryAccess> DictionaryAccessAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        if (_dictionaryAccess is { } known)
        {
            return known;
        }

        OracleDictionaryAccess access;
        try
        {
            await ScalarAsync(connection, OracleUserCatalog.DbaProbe, cancellationToken);
            access = OracleDictionaryAccess.Dba;
        }
        catch (OracleException ex) when (ex.Number == TableOrViewDoesNotExist)
        {
            access = OracleDictionaryAccess.Session;
        }

        _dictionaryAccess = access;
        return access;
    }
}
