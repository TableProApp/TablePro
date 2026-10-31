namespace TablePro.Core.Licensing;

public enum TeamRoleKind
{
    Owner,
    Admin,
    Member,
    Unknown,
}

/// <summary>
/// A member's role on a Team license, as the server signs it. Kept open for the same reason <see cref="LicenseTier"/>
/// is: a role this build does not recognise keeps its raw name instead of failing to read.
/// </summary>
public readonly record struct TeamRole(TeamRoleKind Kind, string Raw)
{
    public static TeamRole Parse(string raw)
    {
        ArgumentNullException.ThrowIfNull(raw);
        var kind = raw.Trim().ToLowerInvariant() switch
        {
            "owner" => TeamRoleKind.Owner,
            "admin" => TeamRoleKind.Admin,
            "member" => TeamRoleKind.Member,
            _ => TeamRoleKind.Unknown,
        };
        return new TeamRole(kind, raw);
    }
}
