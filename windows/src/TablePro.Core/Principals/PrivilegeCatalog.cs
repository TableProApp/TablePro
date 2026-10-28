namespace TablePro.Core.Principals;

/// <summary>The groups the privilege checklist sorts privileges into.</summary>
public static class PrivilegeCategoryKeys
{
    public const string Data = "data";
    public const string Structure = "structure";
    public const string Administration = "administration";
    public const string Dynamic = "dynamic";
}

/// <summary>A privilege the engine can grant: its keyword, the label shown for it, and its checklist group.</summary>
public sealed record PrivilegeDescriptor(string Name, string Label, string? Category = null);

/// <summary>Which privileges can be granted at each level of the server.</summary>
public sealed record PrivilegeCatalog(
    IReadOnlyList<PrivilegeDescriptor> Server,
    IReadOnlyList<PrivilegeDescriptor> Database,
    IReadOnlyList<PrivilegeDescriptor> Schema,
    IReadOnlyList<PrivilegeDescriptor> Table,
    IReadOnlyList<PrivilegeDescriptor> Column,
    bool SupportsDynamicPrivileges = false)
{
    public static PrivilegeCatalog Empty { get; } = new([], [], [], [], []);

    public IReadOnlyList<PrivilegeDescriptor> For(PrivilegeScope scope) => For(scope.Level);

    public IReadOnlyList<PrivilegeDescriptor> For(PrivilegeLevel level) => level switch
    {
        PrivilegeLevel.Server => Server,
        PrivilegeLevel.Database => Database,
        PrivilegeLevel.Schema => Schema,
        PrivilegeLevel.Table => Table,
        _ => Column,
    };
}

/// <summary>
/// Privilege keywords go into GRANT text unquoted, since no engine lets a privilege be quoted. Only upper-case letters,
/// spaces and underscores pass, so a name read from the server or typed by a user cannot carry SQL along with it.
/// </summary>
public static class PrivilegeName
{
    public static string? Sanitize(string raw)
    {
        var normalized = raw.Trim().ToUpperInvariant();
        if (normalized.Length == 0)
        {
            return null;
        }

        foreach (var c in normalized)
        {
            if (c is not ((>= 'A' and <= 'Z') or ' ' or '_'))
            {
                return null;
            }
        }

        return normalized;
    }
}
