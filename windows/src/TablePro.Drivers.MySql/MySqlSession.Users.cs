using System.Data.Common;
using System.Globalization;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Principals;

namespace TablePro.Drivers.MySql;

public sealed partial class MySqlSession : IUserAdministration
{
    // Account statements commit implicitly, so an apply cannot be rolled back and runs without a transaction.
    private static readonly UserAdministrationFeatures MySqlUserFeatures = new(HostScoping: true, ScopeSearch: true, Rename: true);

    private volatile MySqlUserSql _userSql = new();
    private volatile PrivilegeCatalog? _privilegeCatalog;

    // Databend speaks the protocol but keeps no mysql.user and its own GRANT grammar.
    public UserAdministrationFeatures? Features => Profile.Engine switch
    {
        DatabaseEngine.MySql or DatabaseEngine.MariaDb or DatabaseEngine.OceanBase => MySqlUserFeatures,
        DatabaseEngine.TiDb => MySqlUserFeatures with { ConnectionLimit = false },
        _ => null,
    };

    public Task<PrincipalSnapshot> LoadPrincipalsAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var session = await QueryAsync(connection, MySqlUserCatalog.Session, static r => (Account: r.GetString(0), Mode: NullableString(r, 1), Version: NullableString(r, 2)), ct);
                var (account, mode, version) = session[0];
                var noBackslashEscapes = mode?.Contains("NO_BACKSLASH_ESCAPES", StringComparison.OrdinalIgnoreCase) == true;
                _userSql = new MySqlUserSql(MySqlUserSql.SyntaxFor(Profile.Engine, version), noBackslashEscapes);

                var readsLimit = Profile.Engine != DatabaseEngine.TiDb;
                var principals = await QueryAsync(
                    connection,
                    readsLimit ? MySqlUserCatalog.PrincipalsWithLimit : MySqlUserCatalog.Principals,
                    r =>
                    {
                        var limit = readsLimit && !r.IsDBNull(2) ? Convert.ToInt32(r.GetValue(2), CultureInfo.InvariantCulture) : 0;
                        var reference = new PrincipalRef(r.GetString(0), NullableString(r, 1) ?? MySqlUserSql.DefaultHost);
                        return new PrincipalInfo(reference,IsRole: false, CanLogin: true, [], [], limit == 0 ? null : limit);
                    },
                    ct);

                var catalog = await PrivilegeCatalogAsync(connection, ct);
                var databases = await LoadDatabasesAsync(connection, ct);
                return new PrincipalSnapshot(principals, catalog, databases, CurrentDatabase, MySqlUserCatalog.ParseAccount(account));
            },
            cancellationToken);

    public Task<IReadOnlyList<PrincipalGrant>> LoadGrantsAsync(PrincipalRef principal, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrincipalGrant>>(
            async (connection, ct) =>
            {
                var catalog = await PrivilegeCatalogAsync(connection, ct);

                // SHOW GRANTS takes an account name, not a parameter; both halves go through QuoteIdentifier.
                var lines = await QueryAsync(connection, "SHOW GRANTS FOR " + MySqlUserSql.Account(principal), static r => r.GetString(0), ct);
                return lines.Select(MySqlGrantParser.Parse).OfType<MySqlParsedGrant>().SelectMany(g => MySqlUserCatalog.Expand(g, catalog)).ToArray();
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> LoadChildScopesAsync(PrivilegeScope scope, CancellationToken cancellationToken) =>
        WithConnectionAsync<IReadOnlyList<PrivilegeScope>>(
            async (connection, ct) => scope.Level switch
            {
                PrivilegeLevel.Database => await QueryAsync(
                    connection,
                    MySqlUserCatalog.Tables,
                    r => PrivilegeScope.ForTable(scope.Database!, null, r.GetString(0)),
                    ct,
                    ("@database", scope.Database)),
                PrivilegeLevel.Table => await QueryAsync(
                    connection,
                    MySqlUserCatalog.Columns,
                    r => PrivilegeScope.ForColumn(scope.Database!, null, scope.Table!, r.GetString(0)),
                    ct,
                    ("@database", scope.Database),
                    ("@table", scope.Table)),
                _ => [],
            },
            cancellationToken);

    public Task<IReadOnlyList<PrivilegeScope>> SearchScopesAsync(string text, int limit, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            (connection, ct) => QueryAsync(
                connection,
                MySqlUserCatalog.SearchObjects,
                static r => PrivilegeScope.ForTable(r.GetString(0), null, r.GetString(1)),
                ct,
                ("@pattern", MySqlUserCatalog.ContainsPattern(text)),
                ("@limit", Math.Max(1, limit))),
            cancellationToken);

    // A MySQL account owns no objects; DEFINER clauses name it, but they do not stop DROP USER.
    public Task<bool> OwnsObjectsAsync(PrincipalRef principal, CancellationToken cancellationToken) => Task.FromResult(false);

    // A global or database grant covers every object below it, columns included.
    public bool Cascades(PrivilegeScope ancestor, PrivilegeScope descendant) => ancestor.Contains(descendant);

    public IReadOnlyList<PrincipalStatement> BuildStatements(IReadOnlyList<PrincipalChange> changes) => PrincipalScript.Build(_userSql, changes);

    // The privilege list is fixed for the server's lifetime, so it is read once per session.
    private async Task<PrivilegeCatalog> PrivilegeCatalogAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        if (_privilegeCatalog is { } cached)
        {
            return cached;
        }

        var rows = await QueryAsync(connection, MySqlUserCatalog.Privileges, static r => (r.GetString(0), NullableString(r, 1)), cancellationToken);
        var catalog = MySqlUserCatalog.Build(rows);
        _privilegeCatalog = catalog;
        return catalog;
    }
}
