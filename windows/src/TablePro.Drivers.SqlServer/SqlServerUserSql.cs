using TablePro.Core.Principals;
using TablePro.Core.Sql;

namespace TablePro.Drivers.SqlServer;

internal enum SqlServerSecurableKind
{
    Server,
    Database,
    Schema,
    Object,
}

/// <summary>What a SQL Server permission is granted on: the server, the database, a schema, or a table or view.</summary>
internal sealed record SqlServerSecurable(SqlServerSecurableKind Kind, string? Schema = null, string? Name = null)
{
    public static SqlServerSecurable Server { get; } = new(SqlServerSecurableKind.Server);

    public static SqlServerSecurable Database { get; } = new(SqlServerSecurableKind.Database);
}

internal sealed record SqlServerGrant(string Permission, SqlServerSecurable Securable, string? Column = null, bool WithGrantOption = false);

/// <summary>
/// The SQL Server statements for each principal change, given the directory the list was read from. A name the
/// directory lacks is a staged create: a login with a same-named user, or a database role. Database statements run in
/// the directory's database through sp_executesql, whatever database the session has moved to since. Null means SQL
/// Server cannot express the change. Pure, so the text is pinned by unit tests.
/// </summary>
internal sealed class SqlServerUserSql(SqlServerPrincipalDirectory? directory) : IPrincipalSqlGenerator
{
    private static SqlDialect Dialect => SqlServerDialect.Instance;

    public IReadOnlyList<string>? CreatePrincipal(PrincipalDefinition definition) =>
        Create(definition.Ref.Name, definition.Password, definition.CanLogin, definition.MemberOf);

    // SQL Server renames a login and its user separately and keeps no attributes the form edits, so only Can log in
    // and membership reach the server.
    public IReadOnlyList<string>? AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed) =>
        old.Ref != changed.Ref ? null : Alter(old.Ref.Name, old.CanLogin, changed.CanLogin, old.MemberOf, changed.MemberOf);

    public IReadOnlyList<string>? SetPassword(PrincipalRef principal, string password) => SetPassword(principal.Name, password);

    public IReadOnlyList<string>? DropPrincipal(PrincipalRef principal, PrincipalDropOptions options) => Drop(principal.Name);

    public IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) =>
        Convert(grants) is { } converted ? GrantStatements(converted, principal.Name) : null;

    public IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) =>
        Convert(grants) is { } converted ? RevokeStatements(converted, principal.Name) : null;

    // MARK: Principals

    /// <remarks>
    /// CREATE LOGIN takes no bind parameters, so the password is spelled as a literal. A Windows login (FROM WINDOWS)
    /// has no password and is not created here.
    /// </remarks>
    public List<string>? Create(string name, string? password, bool canLogin, IReadOnlyList<string> memberOf)
    {
        List<string> statements;
        if (canLogin)
        {
            if (string.IsNullOrEmpty(password))
            {
                return null;
            }

            statements =
            [
                $"CREATE LOGIN {Q(name)} WITH PASSWORD = {Dialect.StringLiteral(password)}",
                InDatabase($"CREATE USER {Q(name)} FOR LOGIN {Q(name)}"),
            ];
        }
        else
        {
            // A database role cannot join a server role.
            if (memberOf.Any(r => directory?.Entry(r)?.Kind == SqlServerPrincipalKind.ServerRole))
            {
                return null;
            }

            statements = [InDatabase($"CREATE ROLE {Q(name)}")];
        }

        var ensured = new HashSet<string>(StringComparer.Ordinal);
        foreach (var role in memberOf.Order(StringComparer.Ordinal))
        {
            if (Membership(name, role, adding: true, ensured) is not { } membership)
            {
                return null;
            }

            statements.AddRange(membership);
        }

        return statements;
    }

    public List<string>? Alter(string name, bool oldCanLogin, bool newCanLogin, IReadOnlyList<string> oldMemberOf, IReadOnlyList<string> newMemberOf)
    {
        var statements = new List<string>();
        if (oldCanLogin != newCanLogin)
        {
            switch (directory?.Entry(name)?.Kind)
            {
                case SqlServerPrincipalKind.Login:
                    statements.Add($"ALTER LOGIN {Q(name)} {(newCanLogin ? "ENABLE" : "DISABLE")}");
                    break;
                case SqlServerPrincipalKind.DatabaseUser:
                    // A user without a login logs in through the database's CONNECT permission.
                    statements.Add(InDatabase(newCanLogin ? $"GRANT CONNECT TO {Q(name)}" : $"REVOKE CONNECT FROM {Q(name)}"));
                    break;
                default:
                    return null;
            }
        }

        var old = oldMemberOf.ToHashSet(StringComparer.Ordinal);
        var changed = newMemberOf.ToHashSet(StringComparer.Ordinal);
        var ensured = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (role, adding) in old.Except(changed).Order(StringComparer.Ordinal).Select(r => (r, false))
                     .Concat(changed.Except(old).Order(StringComparer.Ordinal).Select(r => (r, true))))
        {
            if (Membership(name, role, adding, ensured) is not { } membership)
            {
                return null;
            }

            statements.AddRange(membership);
        }

        return statements;
    }

    public List<string>? SetPassword(string name, string password)
    {
        var literal = Dialect.StringLiteral(password);
        return directory?.Entry(name)?.Kind switch
        {
            null or SqlServerPrincipalKind.Login => [$"ALTER LOGIN {Q(name)} WITH PASSWORD = {literal}"],
            SqlServerPrincipalKind.DatabaseUser => [InDatabase($"ALTER USER {Q(name)} WITH PASSWORD = {literal}")],
            _ => null,
        };
    }

    /// <summary>
    /// A role must be empty before it is dropped, so its members are removed first, each guarded in case the same
    /// apply already dropped it. A login's users in databases other than the listed one are left orphaned.
    /// </summary>
    public List<string>? Drop(string name)
    {
        if (directory?.Entry(name) is not { } entry)
        {
            return null;
        }

        switch (entry.Kind)
        {
            case SqlServerPrincipalKind.Login:
                return entry.User is { } user ? [InDatabase($"DROP USER {Q(user)}"), $"DROP LOGIN {Q(name)}"] : [$"DROP LOGIN {Q(name)}"];
            case SqlServerPrincipalKind.ServerRole:
                var serverMembers = directory.MembersOf(name).Select(member =>
                    $"IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = {Dialect.StringLiteral(member)}) ALTER SERVER ROLE {Q(name)} DROP MEMBER {Q(member)}");
                return [.. serverMembers, $"DROP SERVER ROLE {Q(name)}"];
            case SqlServerPrincipalKind.DatabaseRole:
                var databaseMembers = directory.MembersOf(name).Select(DatabaseGrantee).OfType<(string Name, string? LoginNeedingUser)>().Select(grantee =>
                    InDatabase($"IF DATABASE_PRINCIPAL_ID({Dialect.StringLiteral(grantee.Name)}) IS NOT NULL ALTER ROLE {Q(name)} DROP MEMBER {Q(grantee.Name)}"));
                return [.. databaseMembers, InDatabase($"DROP ROLE {Q(name)}")];
            default:
                return [InDatabase($"DROP USER {Q(name)}")];
        }
    }

    // MARK: Permissions

    public List<string>? GrantStatements(IReadOnlyList<SqlServerGrant> grants, string principal) => Statements(grants, principal, revoking: false);

    public List<string>? RevokeStatements(IReadOnlyList<SqlServerGrant> grants, string principal) => Statements(grants, principal, revoking: true);

    private List<string>? Statements(IReadOnlyList<SqlServerGrant> grants, string principal, bool revoking)
    {
        var order = new List<(SqlServerSecurable Securable, bool GrantOption)>();
        var whole = new Dictionary<(SqlServerSecurable, bool), List<string>>();
        var byColumn = new Dictionary<(SqlServerSecurable, bool), SortedDictionary<string, List<string>>>();

        foreach (var grant in grants)
        {
            if (PrivilegeName.Sanitize(grant.Permission) is not { } permission)
            {
                continue;
            }

            if (grant.Column is not null && grant.Securable.Kind != SqlServerSecurableKind.Object)
            {
                return null;
            }

            var key = (grant.Securable, grant.WithGrantOption);
            if (!whole.ContainsKey(key) && !byColumn.ContainsKey(key))
            {
                order.Add(key);
            }

            if (grant.Column is { } column)
            {
                if (!byColumn.TryGetValue(key, out var permissions))
                {
                    permissions = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
                    byColumn[key] = permissions;
                }

                if (!permissions.TryGetValue(permission, out var columns))
                {
                    columns = [];
                    permissions[permission] = columns;
                }

                if (!columns.Contains(column))
                {
                    columns.Add(column);
                }
            }
            else
            {
                if (!whole.TryGetValue(key, out var permissions))
                {
                    permissions = [];
                    whole[key] = permissions;
                }

                if (!permissions.Contains(permission))
                {
                    permissions.Add(permission);
                }
            }
        }

        var statements = new List<string>();
        var ensured = new HashSet<string>(StringComparer.Ordinal);
        foreach (var key in order)
        {
            var clause = new List<string>(whole.TryGetValue(key, out var permissions) ? permissions : []);
            if (byColumn.TryGetValue(key, out var columns))
            {
                clause.AddRange(columns.Select(c => $"{c.Key} ({string.Join(", ", c.Value.Select(Q))})"));
            }

            if (clause.Count == 0)
            {
                continue;
            }

            // Server permissions must be granted in master (Msg 4621).
            if (key.Securable.Kind == SqlServerSecurableKind.Server)
            {
                if (!IsServerGrantee(principal))
                {
                    return null;
                }

                statements.Add(InDatabase("master", PermissionStatement(string.Join(", ", clause), null, Q(principal), key.GrantOption, revoking)));
                continue;
            }

            if (DatabaseGrantee(principal) is not { } grantee)
            {
                return null;
            }

            if (grantee.LoginNeedingUser is { } login && !revoking && ensured.Add(login))
            {
                statements.Add(InDatabase(EnsureUser(login)));
            }

            statements.Add(InDatabase(PermissionStatement(string.Join(", ", clause), Target(key.Securable), Q(grantee.Name), key.GrantOption, revoking)));
        }

        return statements;
    }

    // A grant made WITH GRANT OPTION can only be revoked with CASCADE (Msg 4611).
    private static string PermissionStatement(string clause, string? target, string grantee, bool withGrantOption, bool revoking)
    {
        var on = target is null ? string.Empty : " ON " + target;
        return revoking
            ? $"REVOKE {clause}{on} FROM {grantee}{(withGrantOption ? " CASCADE" : string.Empty)}"
            : $"GRANT {clause}{on} TO {grantee}{(withGrantOption ? " WITH GRANT OPTION" : string.Empty)}";
    }

    private static string? Target(SqlServerSecurable securable) => securable.Kind switch
    {
        SqlServerSecurableKind.Schema => "SCHEMA::" + Q(securable.Schema!),
        SqlServerSecurableKind.Object => $"OBJECT::{Q(securable.Schema!)}.{Q(securable.Name!)}",
        _ => null,
    };

    // Statements run in the database the list was read from, so a scope naming another database is refused.
    private List<SqlServerGrant>? Convert(IReadOnlyList<PrincipalGrant> grants)
    {
        var converted = new List<SqlServerGrant>(grants.Count);
        foreach (var grant in grants)
        {
            var scope = grant.Scope;
            if (directory is not null && scope.Database is { } database && database != directory.Database)
            {
                return null;
            }

            var securable = scope.Level switch
            {
                PrivilegeLevel.Server => SqlServerSecurable.Server,
                PrivilegeLevel.Database => SqlServerSecurable.Database,
                PrivilegeLevel.Schema => new SqlServerSecurable(SqlServerSecurableKind.Schema, scope.Schema),
                _ => new SqlServerSecurable(SqlServerSecurableKind.Object, scope.Schema ?? "dbo", scope.Table),
            };
            converted.Add(new SqlServerGrant(grant.Privilege, securable, scope.Column, grant.IsGrantable));
        }

        return converted;
    }

    // MARK: Grantees

    private bool IsServerGrantee(string name) =>
        directory?.Entry(name)?.Kind is null or SqlServerPrincipalKind.Login or SqlServerPrincipalKind.ServerRole;

    /// <summary>
    /// Who a database statement names for a principal: a login's mapped user, or the login itself when it has no user
    /// yet, in which case one is created first.
    /// </summary>
    private (string Name, string? LoginNeedingUser)? DatabaseGrantee(string name) => directory?.Entry(name) switch
    {
        { Kind: SqlServerPrincipalKind.Login, User: { } user } => (user, null),
        { Kind: SqlServerPrincipalKind.Login } => (name, name),
        { Kind: SqlServerPrincipalKind.ServerRole } => null,
        _ => (name, null),
    };

    private List<string>? Membership(string member, string role, bool adding, HashSet<string> ensured)
    {
        var verb = adding ? "ADD" : "DROP";
        var roleKind = directory?.Entry(role)?.Kind;
        if (roleKind == SqlServerPrincipalKind.ServerRole)
        {
            return IsServerGrantee(member) ? [$"ALTER SERVER ROLE {Q(role)} {verb} MEMBER {Q(member)}"] : null;
        }

        if (roleKind is not (null or SqlServerPrincipalKind.DatabaseRole) || DatabaseGrantee(member) is not { } grantee)
        {
            return null;
        }

        var statements = new List<string>();
        if (grantee.LoginNeedingUser is { } login && adding && ensured.Add(login))
        {
            statements.Add(InDatabase(EnsureUser(login)));
        }

        statements.Add(InDatabase($"ALTER ROLE {Q(role)} {verb} MEMBER {Q(grantee.Name)}"));
        return statements;
    }

    // MARK: Spelling

    private string InDatabase(string statement) =>
        directory is { Database.Length: > 0 } ? InDatabase(directory.Database, statement) : statement;

    /// <summary>
    /// A system procedure called through a database name runs in that database, so no USE moves the session. The
    /// statement travels as an N'' literal, the only form sp_executesql's first argument takes from a batch like this.
    /// </summary>
    public static string InDatabase(string database, string statement) => $"EXEC {Q(database)}.sys.sp_executesql {Dialect.StringLiteral(statement)}";

    /// <summary>
    /// A login reaches a database only through a user. A same-named user with another SID makes CREATE USER fail rather
    /// than quietly take the login's grants.
    /// </summary>
    public static string EnsureUser(string login)
    {
        var name = Dialect.StringLiteral(login);
        return $"IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = {name} AND sid = SUSER_SID({name})) CREATE USER {Q(login)} FOR LOGIN {Q(login)}";
    }

    private static string Q(string name) => Dialect.QuoteIdentifier(name);
}
