using System.Globalization;
using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Principals;
using TablePro.Core.Sql;

namespace TablePro.Drivers.MySql;

/// <summary>Which account grammar a server takes.</summary>
internal enum MySqlAccountSyntax
{
    /// <summary>ALTER USER ... IDENTIFIED BY and WITH MAX_USER_CONNECTIONS: MySQL 5.7.6 and MariaDB 10.2.0 onward.</summary>
    AlterUser,

    /// <summary>GRANT USAGE ON *.* TO ... for both, the only spelling older servers take and MySQL 8 removed.</summary>
    GrantUsage,
}

/// <summary>
/// The MySQL and MariaDB statements for each account change. An account is a user at a host, and MySQL has no roles in
/// the editor's sense, so membership is not offered. Pure, so the text is pinned by unit tests.
/// </summary>
/// <param name="syntax">The account grammar the server takes, from its version.</param>
/// <param name="noBackslashEscapes">
/// The session runs with NO_BACKSLASH_ESCAPES, where a backslash in a literal is an ordinary character; doubling it
/// there would silently set a different password.
/// </param>
internal sealed class MySqlUserSql(MySqlAccountSyntax syntax = MySqlAccountSyntax.AlterUser, bool noBackslashEscapes = false) : IPrincipalSqlGenerator
{
    public const string DefaultHost = "%";

    private static SqlDialect Dialect => MySqlDialect.Instance;

    public static MySqlAccountSyntax SyntaxFor(DatabaseEngine engine, string? version) => engine switch
    {
        DatabaseEngine.MySql => IsKnownBelow(version, 5, 7, 6) ? MySqlAccountSyntax.GrantUsage : MySqlAccountSyntax.AlterUser,
        DatabaseEngine.MariaDb => IsKnownBelow(version, 10, 2, 0) ? MySqlAccountSyntax.GrantUsage : MySqlAccountSyntax.AlterUser,

        // TiDB and OceanBase report a MySQL version that says nothing about their own grammar.
        _ => MySqlAccountSyntax.AlterUser,
    };

    /// <summary>Whether a VERSION() string is below the given release; an unreadable one is assumed current.</summary>
    public static bool IsKnownBelow(string? version, int major, int minor, int patch)
    {
        if (version is null)
        {
            return false;
        }

        // "8.0.36-0ubuntu0.22.04.1" and "10.6.12-MariaDB-log" both lead with the release; the rest is the build.
        var numbers = new List<int>(3);
        foreach (var part in version.Split('.'))
        {
            var digits = part.Length - part.AsSpan().TrimStart("0123456789").Length;
            if (digits == 0 || !int.TryParse(part.AsSpan(0, digits), NumberStyles.None, CultureInfo.InvariantCulture, out var number))
            {
                break;
            }

            numbers.Add(number);
            if (digits != part.Length || numbers.Count == 3)
            {
                break;
            }
        }

        if (numbers.Count == 0)
        {
            return false;
        }

        while (numbers.Count < 3)
        {
            numbers.Add(0);
        }

        return (numbers[0], numbers[1], numbers[2]).CompareTo((major, minor, patch)) < 0;
    }

    public static string Account(PrincipalRef principal) => $"{Q(principal.Name)}@{Q(principal.Host ?? DefaultHost)}";

    // IDENTIFIED BY takes a string literal only, never a parameter or an expression, so the password is spelled inline.
    public string Literal(string value) =>
        noBackslashEscapes ? string.Concat("'", value.Replace("'", "''", StringComparison.Ordinal), "'") : Dialect.StringLiteral(value);

    public IReadOnlyList<string> CreatePrincipal(PrincipalDefinition definition)
    {
        var statement = "CREATE USER " + Account(definition.Ref);
        if (definition.HasPassword)
        {
            statement += " IDENTIFIED BY " + Literal(definition.Password!);
        }

        if (definition.ConnectionLimit is not { } limit)
        {
            return [statement];
        }

        // CREATE USER comes first because it is what fails on a duplicate account: the legacy GRANT on its own would
        // quietly create a passwordless one instead.
        return syntax == MySqlAccountSyntax.AlterUser
            ? [statement + " WITH MAX_USER_CONNECTIONS " + limit.ToString(CultureInfo.InvariantCulture)]
            : [statement, ConnectionLimit(limit, definition.Ref)];
    }

    // 0 is MySQL's spelling of no limit.
    public IReadOnlyList<string> AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed)
    {
        var statements = new List<string>();
        if (old.ConnectionLimit != changed.ConnectionLimit)
        {
            statements.Add(ConnectionLimit(changed.ConnectionLimit ?? 0, old.Ref));
        }

        if (old.Ref != changed.Ref)
        {
            statements.Add($"RENAME USER {Account(old.Ref)} TO {Account(changed.Ref)}");
        }

        return statements;
    }

    /// <remarks>
    /// The legacy spelling is GRANT USAGE ... IDENTIFIED BY rather than SET PASSWORD, which on MariaDB 10.1 answers OK
    /// for an account on an authentication plugin and leaves the plugin, and so the old login, in place.
    /// </remarks>
    public IReadOnlyList<string> SetPassword(PrincipalRef principal, string password) =>
        syntax == MySqlAccountSyntax.AlterUser
            ? [$"ALTER USER {Account(principal)} IDENTIFIED BY {Literal(password)}"]
            : [$"GRANT USAGE ON *.* TO {Account(principal)} IDENTIFIED BY {Literal(password)}"];

    public IReadOnlyList<string> DropPrincipal(PrincipalRef principal, PrincipalDropOptions options) => ["DROP USER " + Account(principal)];

    public IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => Builder(principal).GrantStatements(grants);

    public IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => Builder(principal).RevokeStatements(grants);

    /// <summary>
    /// MySQL reads the database in a global or database-level target as a LIKE pattern, so its _ and % are escaped there.
    /// A table-level target names the database literally, and escaping it would grant on a different name.
    /// </summary>
    public static string? GrantTarget(PrivilegeScope scope) => scope.Level switch
    {
        PrivilegeLevel.Server => "*.*",
        PrivilegeLevel.Database or PrivilegeLevel.Schema => Q(EscapeDatabasePattern(scope.Database!)) + ".*",
        PrivilegeLevel.Table or PrivilegeLevel.Column => $"{Q(scope.Database!)}.{Q(scope.Table!)}",
        _ => null,
    };

    public static string EscapeDatabasePattern(string name)
    {
        var result = new StringBuilder(name.Length + 4);
        foreach (var c in name)
        {
            if (c is '\\' or '_' or '%')
            {
                result.Append('\\');
            }

            result.Append(c);
        }

        return result.ToString();
    }

    private string ConnectionLimit(int limit, PrincipalRef principal)
    {
        var count = limit.ToString(CultureInfo.InvariantCulture);
        return syntax == MySqlAccountSyntax.AlterUser
            ? $"ALTER USER {Account(principal)} WITH MAX_USER_CONNECTIONS {count}"
            : $"GRANT USAGE ON *.* TO {Account(principal)} WITH MAX_USER_CONNECTIONS {count}";
    }

    private static GrantSqlBuilder Builder(PrincipalRef principal) => new(Account(principal), Q, GrantTarget);

    private static string Q(string name) => Dialect.QuoteIdentifier(name);
}
