using TablePro.Core.Localization;

namespace TablePro.Core.Principals;

/// <summary>A login, user or role. MySQL names an account by user and host together; other engines leave the host null.</summary>
public sealed record PrincipalRef(string Name, string? Host = null)
{
    public string DisplayName => string.IsNullOrEmpty(Host) ? Name : $"{Name}@{Host}";

    public override string ToString() => DisplayName;
}

/// <summary>A yes-or-no property of a principal, such as PostgreSQL's CREATEDB, keyed by the engine's own keyword.</summary>
public sealed record PrincipalAttribute(string Key, string Label, bool IsEnabled);

/// <summary>A principal as the server reports it.</summary>
public sealed record PrincipalInfo(
    PrincipalRef Ref,
    bool IsRole,
    bool CanLogin,
    IReadOnlyList<PrincipalAttribute> Attributes,
    IReadOnlyList<string> MemberOf,
    int? ConnectionLimit = null,
    string? Comment = null)
{
    public PrincipalInfo(PrincipalRef reference, bool isRole = false, bool canLogin = true)
        : this(reference, isRole, canLogin, [], [])
    {
    }
}

/// <summary>
/// What a principal should be: the create sheet's result, or an attributes edit. The lists compare by content, so a
/// draft edited back to what the server has counts as no change.
/// </summary>
public sealed record PrincipalDefinition(
    PrincipalRef Ref,
    string? Password,
    bool CanLogin,
    IReadOnlyList<PrincipalAttribute> Attributes,
    IReadOnlyList<string> MemberOf,
    int? ConnectionLimit = null,
    string? Comment = null)
{
    public PrincipalDefinition(PrincipalRef reference, string? password = null, bool canLogin = true)
        : this(reference, password, canLogin, [], [])
    {
    }

    public bool HasPassword => !string.IsNullOrEmpty(Password);

    public static PrincipalDefinition From(PrincipalInfo info) =>
        new(info.Ref, null, info.CanLogin, info.Attributes, info.MemberOf, info.ConnectionLimit, info.Comment);

    public PrincipalDefinition MaskingPassword(string placeholder) => HasPassword ? this with { Password = placeholder } : this;

    public bool Equals(PrincipalDefinition? other) =>
        other is not null
        && Ref == other.Ref
        && Password == other.Password
        && CanLogin == other.CanLogin
        && Attributes.SequenceEqual(other.Attributes)
        && MemberOf.SequenceEqual(other.MemberOf, StringComparer.Ordinal)
        && ConnectionLimit == other.ConnectionLimit
        && Comment == other.Comment;

    public override int GetHashCode() => HashCode.Combine(Ref, Password, CanLogin, Attributes.Count, MemberOf.Count, ConnectionLimit, Comment);
}

/// <summary>What happens to the objects a dropped PostgreSQL role owns. Other engines ignore it.</summary>
public sealed record PrincipalDropOptions(PrincipalRef? ReassignOwnedTo = null, bool DropOwned = false)
{
    public static PrincipalDropOptions None { get; } = new();
}

/// <summary>One privilege held on one scope, and whether its holder may pass it on.</summary>
public sealed record PrincipalGrant(string Privilege, PrivilegeScope Scope, bool IsGrantable = false);

/// <summary>The grants one principal gains and loses in an apply.</summary>
public sealed record PrincipalGrantChanges(PrincipalRef Principal, IReadOnlyList<PrincipalGrant> Added, IReadOnlyList<PrincipalGrant> Removed);

/// <summary>Where a principal stands against the server while edits are staged.</summary>
public enum PrincipalStage
{
    Unchanged,
    Created,
    Modified,
    Dropped,
}

/// <summary>A row of the principal list: the principal and what the staged edits do to it.</summary>
public sealed record PrincipalRow(PrincipalInfo Info, PrincipalStage Stage)
{
    public PrincipalRef Ref => Info.Ref;

    public string DisplayName => Info.Ref.DisplayName;

    public string KindTitle => CoreStrings.Get(Info.IsRole ? "Principal/KindRole" : "Principal/KindUser");

    /// <summary>The enabled attributes, so a superuser stands out in the list without opening it.</summary>
    public string AttributeSummary => string.Join(", ", Info.Attributes.Where(a => a.IsEnabled).Select(a => a.Label));

    public string? StageDescription => Stage switch
    {
        PrincipalStage.Created => CoreStrings.Get("Principal/StageCreated"),
        PrincipalStage.Modified => CoreStrings.Get("Principal/StageModified"),
        PrincipalStage.Dropped => CoreStrings.Get("Principal/StageDropped"),
        _ => null,
    };
}
