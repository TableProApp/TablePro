namespace TablePro.Drivers.SqlServer;

internal enum SqlServerPrincipalKind
{
    /// <summary>A server login; <see cref="SqlServerPrincipalEntry.User"/> is the database user sharing its SID, if any.</summary>
    Login,
    ServerRole,
    DatabaseRole,

    /// <summary>A user no visible login maps to: contained, WITHOUT LOGIN, or orphaned.</summary>
    DatabaseUser,
}

/// <summary>One principal of the list. IsEnabled means a login not disabled, or a database user holding CONNECT.</summary>
internal sealed record SqlServerPrincipalEntry(string Name, SqlServerPrincipalKind Kind, string? User, bool IsEnabled, IReadOnlyList<string> MemberOf)
{
    public bool IsRole => Kind is SqlServerPrincipalKind.ServerRole or SqlServerPrincipalKind.DatabaseRole;
}

internal sealed record SqlServerLoginRow(string Name, bool IsDisabled, string? User);

internal sealed record SqlServerDatabasePrincipalRow(string Name, bool IsRole, bool HasConnect);

internal sealed record SqlServerMembershipRow(string Member, string Role);

/// <summary>
/// SQL Server keeps principals at two levels, logins and server roles above, users and database roles in each database.
/// The editor shows one list: a login stands for the user sharing its SID in the database the list was read from (sa
/// is dbo there), and a name used at both levels keeps the first of login, server role, database role, database user.
/// </summary>
internal sealed class SqlServerPrincipalDirectory
{
    private readonly Dictionary<string, SqlServerPrincipalEntry> _byName;

    public SqlServerPrincipalDirectory(
        string database,
        IEnumerable<SqlServerLoginRow> logins,
        IEnumerable<string> serverRoles,
        IEnumerable<SqlServerDatabasePrincipalRow> databasePrincipals,
        IEnumerable<SqlServerMembershipRow> serverMemberships,
        IEnumerable<SqlServerMembershipRow> databaseMemberships)
    {
        var databaseRows = databasePrincipals.ToArray();
        var candidates = new List<(string Name, SqlServerPrincipalKind Kind, string? User, bool Enabled)>();
        candidates.AddRange(logins.Select(l => (l.Name, SqlServerPrincipalKind.Login, l.User, !l.IsDisabled)));
        candidates.AddRange(serverRoles.Select(r => (r, SqlServerPrincipalKind.ServerRole, (string?)null, true)));
        candidates.AddRange(databaseRows.Where(p => p.IsRole).Select(p => (p.Name, SqlServerPrincipalKind.DatabaseRole, (string?)null, true)));
        candidates.AddRange(databaseRows.Where(p => !p.IsRole).Select(p => (p.Name, SqlServerPrincipalKind.DatabaseUser, (string?)null, p.HasConnect)));

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var kept = candidates.Where(c => seen.Add(c.Name)).ToArray();

        // Database memberships name users; map each back to the entry that stands for it.
        var entryByUser = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var candidate in kept)
        {
            if (candidate.Kind == SqlServerPrincipalKind.Login && candidate.User is { } user)
            {
                entryByUser[user] = candidate.Name;
            }
            else if (candidate.Kind is SqlServerPrincipalKind.DatabaseRole or SqlServerPrincipalKind.DatabaseUser)
            {
                entryByUser[candidate.Name] = candidate.Name;
            }
        }

        var serverNames = kept.Where(c => c.Kind is SqlServerPrincipalKind.Login or SqlServerPrincipalKind.ServerRole).Select(c => c.Name).ToHashSet(StringComparer.Ordinal);
        var serverRoleNames = kept.Where(c => c.Kind == SqlServerPrincipalKind.ServerRole).Select(c => c.Name).ToHashSet(StringComparer.Ordinal);
        var databaseRoleNames = kept.Where(c => c.Kind == SqlServerPrincipalKind.DatabaseRole).Select(c => c.Name).ToHashSet(StringComparer.Ordinal);

        var memberOf = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        void Add(string member, string role)
        {
            if (!memberOf.TryGetValue(member, out var roles))
            {
                roles = new SortedSet<string>(StringComparer.Ordinal);
                memberOf[member] = roles;
            }

            roles.Add(role);
        }

        foreach (var row in serverMemberships.Where(r => serverRoleNames.Contains(r.Role) && serverNames.Contains(r.Member)))
        {
            Add(row.Member, row.Role);
        }

        foreach (var row in databaseMemberships.Where(r => databaseRoleNames.Contains(r.Role)))
        {
            if (entryByUser.TryGetValue(row.Member, out var member))
            {
                Add(member, row.Role);
            }
        }

        Database = database;
        Entries = kept.Select(c => new SqlServerPrincipalEntry(c.Name, c.Kind, c.User, c.Enabled, memberOf.TryGetValue(c.Name, out var roles) ? [.. roles] : [])).ToArray();
        _byName = Entries.ToDictionary(e => e.Name, StringComparer.Ordinal);
    }

    /// <summary>The database the list was read from; every database statement runs there.</summary>
    public string Database { get; }

    public IReadOnlyList<SqlServerPrincipalEntry> Entries { get; }

    public SqlServerPrincipalEntry? Entry(string name) => _byName.GetValueOrDefault(name);

    public IEnumerable<string> MembersOf(string role) => Entries.Where(e => e.MemberOf.Contains(role)).Select(e => e.Name);
}
