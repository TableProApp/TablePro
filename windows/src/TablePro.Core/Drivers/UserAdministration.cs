using TablePro.Core.Principals;

namespace TablePro.Core.Drivers;

/// <summary>
/// The Users and Roles editor: an engine's principals, the privileges they hold at each level of the server, and the
/// statements that change them. A session implements it beside <see cref="IUserListProvider"/>, which stays the plain
/// read-only list for engines without an editor.
/// </summary>
/// <remarks>
/// Building statements is separate from running them, as with <see cref="ISchemaDdlProvider"/>: the app shows them for
/// review and runs them itself, so Safe Mode and history apply the way they do to any other DDL.
/// </remarks>
public interface IUserAdministration
{
    /// <summary>
    /// What the editor offers, or null when this connection's engine has none. One session class serves several engines
    /// that share a wire protocol, and only some of them keep the catalog the editor reads.
    /// </summary>
    UserAdministrationFeatures? Features { get; }

    /// <summary>Every principal with its attributes and memberships, the privilege catalog, and where the session stands.</summary>
    Task<PrincipalSnapshot> LoadPrincipalsAsync(CancellationToken cancellationToken);

    /// <summary>The grants a principal holds directly, at every level the engine reads.</summary>
    Task<IReadOnlyList<PrincipalGrant>> LoadGrantsAsync(PrincipalRef principal, CancellationToken cancellationToken);

    /// <summary>The objects one level below <paramref name="scope"/> that privileges can be granted on.</summary>
    Task<IReadOnlyList<PrivilegeScope>> LoadChildScopesAsync(PrivilegeScope scope, CancellationToken cancellationToken);

    /// <summary>Tables and views whose name contains <paramref name="text"/>, at most <paramref name="limit"/> of them.</summary>
    Task<IReadOnlyList<PrivilegeScope>> SearchScopesAsync(string text, int limit, CancellationToken cancellationToken);

    /// <summary>Whether dropping the principal needs its objects reassigned or dropped first.</summary>
    Task<bool> OwnsObjectsAsync(PrincipalRef principal, CancellationToken cancellationToken);

    /// <summary>Whether a grant on <paramref name="ancestor"/> also covers <paramref name="descendant"/> on this engine.</summary>
    bool Cascades(PrivilegeScope ancestor, PrivilegeScope descendant);

    /// <summary>The statements for the staged changes in the order they must run, without running them.</summary>
    /// <exception cref="UnsupportedPrincipalChangeException">A change the engine cannot express; nothing should run.</exception>
    IReadOnlyList<PrincipalStatement> BuildStatements(IReadOnlyList<PrincipalChange> changes);
}

/// <summary>What the editor offers on an engine.</summary>
/// <param name="HostScoping">Accounts are a user at a host, as in MySQL.</param>
/// <param name="RoleMembership">Principals can belong to roles.</param>
/// <param name="OwnedObjectReassignment">A principal can own objects, which a drop must reassign or drop.</param>
/// <param name="ScopeSearch">The scope tree can search tables by name.</param>
/// <param name="RestrictsBrowsingToCurrentDatabase">Below the database level only the connected database can be read.</param>
/// <param name="ConnectionLimit">A principal can carry a connection limit.</param>
/// <param name="RoleLogin">A role may be allowed to log in, so Can log in is editable on roles too.</param>
/// <param name="Rename">A principal can be renamed in place, keeping its grants.</param>
/// <param name="Transaction">How to run an apply atomically, or null where the statements commit on their own.</param>
public sealed record UserAdministrationFeatures(
    bool HostScoping = false,
    bool RoleMembership = false,
    bool OwnedObjectReassignment = false,
    bool ScopeSearch = false,
    bool RestrictsBrowsingToCurrentDatabase = false,
    bool ConnectionLimit = true,
    bool RoleLogin = true,
    bool Rename = false,
    PrincipalTransaction? Transaction = null);

/// <summary>The statements that wrap an apply, so a failure part way leaves the server as it was.</summary>
public sealed record PrincipalTransaction(string Begin, string Commit, string Rollback);

/// <summary>One read of the server's principals.</summary>
/// <param name="Principals">Every principal the editor can manage, with attributes and memberships.</param>
/// <param name="Catalog">The privileges that can be granted at each level.</param>
/// <param name="Databases">The roots of the scope tree.</param>
/// <param name="CurrentDatabase">The database the grants below database level were read from.</param>
/// <param name="CurrentPrincipal">The account this connection uses, so the review can warn before it is locked out.</param>
public sealed record PrincipalSnapshot(
    IReadOnlyList<PrincipalInfo> Principals,
    PrivilegeCatalog Catalog,
    IReadOnlyList<string> Databases,
    string? CurrentDatabase,
    PrincipalRef? CurrentPrincipal);
