namespace TablePro.Core.Principals;

/// <summary>One staged edit to the server's principals, as the review lists it and the apply runs it.</summary>
public abstract record PrincipalChange
{
    private protected PrincipalChange()
    {
    }

    public abstract PrincipalRef Principal { get; }

    /// <summary>Whether running it can take something away: a drop, or a revoke.</summary>
    public abstract bool IsDestructive { get; }

    /// <summary>
    /// The order changes run in: a new principal must exist before it is altered or granted to, and a dropped one must
    /// keep existing until the grants that name it have been revoked.
    /// </summary>
    internal abstract int ExecutionRank { get; }

    /// <summary>The same change with any password replaced, for a review that must not show it.</summary>
    public virtual PrincipalChange MaskingPassword(string placeholder) => this;
}

public sealed record CreatePrincipal(PrincipalDefinition Definition) : PrincipalChange
{
    public override PrincipalRef Principal => Definition.Ref;

    public override bool IsDestructive => false;

    internal override int ExecutionRank => 0;

    public override PrincipalChange MaskingPassword(string placeholder) => this with { Definition = Definition.MaskingPassword(placeholder) };
}

public sealed record AlterPrincipal(PrincipalDefinition Old, PrincipalDefinition New) : PrincipalChange
{
    public override PrincipalRef Principal => Old.Ref;

    public override bool IsDestructive => false;

    internal override int ExecutionRank => 1;

    public override PrincipalChange MaskingPassword(string placeholder) =>
        this with { Old = Old.MaskingPassword(placeholder), New = New.MaskingPassword(placeholder) };
}

public sealed record SetPrincipalPassword(PrincipalRef Ref, string Password) : PrincipalChange
{
    public override PrincipalRef Principal => Ref;

    public override bool IsDestructive => false;

    internal override int ExecutionRank => 2;

    public override PrincipalChange MaskingPassword(string placeholder) => Password.Length == 0 ? this : this with { Password = placeholder };
}

public sealed record ModifyGrants(PrincipalGrantChanges Changes) : PrincipalChange
{
    public override PrincipalRef Principal => Changes.Principal;

    public override bool IsDestructive => Changes.Removed.Count > 0;

    internal override int ExecutionRank => 3;
}

public sealed record DropPrincipal(PrincipalRef Ref, PrincipalDropOptions Options) : PrincipalChange
{
    public override PrincipalRef Principal => Ref;

    public override bool IsDestructive => true;

    internal override int ExecutionRank => 4;
}

/// <summary>
/// One statement of an apply. <see cref="CarriesCredentials"/> marks text with a password in it, which the app keeps out
/// of query history because history is stored unencrypted.
/// </summary>
public sealed record PrincipalStatement(string Sql, string Description, bool IsDestructive, bool CarriesCredentials = false);

/// <summary>Thrown when an engine has no statement for a staged change, so nothing runs rather than part of it.</summary>
public sealed class UnsupportedPrincipalChangeException : Exception
{
    public UnsupportedPrincipalChangeException()
    {
    }

    public UnsupportedPrincipalChangeException(string message)
        : base(message)
    {
    }

    public UnsupportedPrincipalChangeException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
