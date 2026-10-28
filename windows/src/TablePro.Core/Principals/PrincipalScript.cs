namespace TablePro.Core.Principals;

/// <summary>
/// An engine's spelling of each principal change. Pure, so each driver pins its text in unit tests; null means the engine
/// cannot express the change, for example a SQL Server database role asked to join a server role.
/// </summary>
public interface IPrincipalSqlGenerator
{
    IReadOnlyList<string>? CreatePrincipal(PrincipalDefinition definition);

    IReadOnlyList<string>? AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed);

    IReadOnlyList<string>? SetPassword(PrincipalRef principal, string password);

    IReadOnlyList<string>? DropPrincipal(PrincipalRef principal, PrincipalDropOptions options);

    IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants);

    IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants);
}

/// <summary>Turns staged changes into the statements an apply runs, in the order they must run.</summary>
public static class PrincipalScript
{
    /// <summary>What the review shows where a password goes.</summary>
    public const string PasswordPlaceholder = "<password>";

    /// <exception cref="UnsupportedPrincipalChangeException">A change the engine cannot express.</exception>
    public static IReadOnlyList<PrincipalStatement> Build(IPrincipalSqlGenerator generator, IEnumerable<PrincipalChange> changes)
    {
        var statements = new List<PrincipalStatement>();
        foreach (var change in changes.OrderBy(c => c.ExecutionRank))
        {
            statements.AddRange(Statements(generator, change));
        }

        return statements;
    }

    private static IEnumerable<PrincipalStatement> Statements(IPrincipalSqlGenerator generator, PrincipalChange change) => change switch
    {
        CreatePrincipal create => Wrap(generator.CreatePrincipal(create.Definition), change, $"Create {create.Principal}", false, create.Definition.HasPassword),
        AlterPrincipal alter => Wrap(generator.AlterPrincipal(alter.Old, alter.New), change, $"Update {alter.Principal}", false, alter.New.HasPassword),
        SetPrincipalPassword password => Wrap(generator.SetPassword(password.Ref, password.Password), change, $"Change password for {password.Ref}", false, true),
        ModifyGrants grants => GrantStatements(generator, grants),
        DropPrincipal drop => Wrap(generator.DropPrincipal(drop.Ref, drop.Options), change, $"Drop {drop.Ref}", true, false),
        _ => throw new UnsupportedPrincipalChangeException($"Unknown change {change.GetType().Name}."),
    };

    // Revokes run first, so a privilege moved between grantable and not is never held twice in between.
    private static List<PrincipalStatement> GrantStatements(IPrincipalSqlGenerator generator, ModifyGrants change)
    {
        var principal = change.Changes.Principal;
        var statements = new List<PrincipalStatement>();
        if (change.Changes.Removed.Count > 0)
        {
            statements.AddRange(Wrap(generator.Revoke(principal, change.Changes.Removed), change, $"Revoke privileges from {principal}", true, false));
        }

        if (change.Changes.Added.Count > 0)
        {
            statements.AddRange(Wrap(generator.Grant(principal, change.Changes.Added), change, $"Grant privileges to {principal}", false, false));
        }

        return statements;
    }

    private static IEnumerable<PrincipalStatement> Wrap(IReadOnlyList<string>? sql, PrincipalChange change, string description, bool destructive, bool credentials) =>
        sql is null
            ? throw new UnsupportedPrincipalChangeException($"This server cannot apply \"{description}\" for {change.Principal}.")
            : sql.Select(s => new PrincipalStatement(s, description, destructive, credentials));
}
