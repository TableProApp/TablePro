using TablePro.Core.Localization;

namespace TablePro.Core.Principals;

/// <summary>A privilege as one grant on one scope, without the grant option, which does not decide whether it is held.</summary>
public readonly record struct PrincipalGrantKey(string Privilege, PrivilegeScope Scope);

public enum EffectivenessKind
{
    NotEffective,
    Direct,
    ViaScope,
    ViaRole,
}

/// <summary>
/// Why a principal holds a privilege it was not granted on this scope: a grant on an object above it that the engine
/// carries down, or a role it belongs to. <see cref="InheritsAutomatically"/> is false for a PostgreSQL NOINHERIT role,
/// whose privileges arrive only after SET ROLE.
/// </summary>
public sealed record PrivilegeEffectiveness(EffectivenessKind Kind, PrivilegeScope? Scope = null, string? Role = null, bool InheritsAutomatically = true)
{
    public static PrivilegeEffectiveness NotEffective { get; } = new(EffectivenessKind.NotEffective);

    public static PrivilegeEffectiveness Direct { get; } = new(EffectivenessKind.Direct);

    public bool IsEffective => Kind != EffectivenessKind.NotEffective;

    public string? Description => Kind switch
    {
        EffectivenessKind.ViaScope => CoreStrings.Format("Principal/GrantedOn", Scope!.DisplayName),
        EffectivenessKind.ViaRole => CoreStrings.Format("Principal/InheritedFrom", Role),
        _ => null,
    };

    public string? Detail => Kind == EffectivenessKind.ViaRole
        ? InheritsAutomatically ? CoreStrings.Get("Principal/InheritedAutomatically") : CoreStrings.Format("Principal/AvailableAfterSetRole", Role)
        : null;
}

/// <summary>What the resolver needs beyond the principal's own grants.</summary>
public sealed record PrivilegeInheritanceContext(
    IReadOnlyDictionary<PrincipalRef, IReadOnlySet<PrincipalGrantKey>> GrantsByPrincipal,
    IReadOnlyList<string> RoleClosure,
    bool InheritsAutomatically,
    Func<PrivilegeScope, PrivilegeScope, bool> Cascades);

public static class PrivilegeEffectivenessResolver
{
    public static PrivilegeEffectiveness Resolve(string privilege, PrivilegeScope scope, IReadOnlySet<PrincipalGrantKey> directGrants, PrivilegeInheritanceContext context)
    {
        if (directGrants.Contains(new PrincipalGrantKey(privilege, scope)))
        {
            return PrivilegeEffectiveness.Direct;
        }

        if (CascadingAncestor(privilege, scope, directGrants, context.Cascades) is { } ancestor)
        {
            return new PrivilegeEffectiveness(EffectivenessKind.ViaScope, ancestor);
        }

        foreach (var role in context.RoleClosure)
        {
            if (!context.GrantsByPrincipal.TryGetValue(new PrincipalRef(role), out var grants))
            {
                continue;
            }

            if (grants.Contains(new PrincipalGrantKey(privilege, scope)) || CascadingAncestor(privilege, scope, grants, context.Cascades) is not null)
            {
                return new PrivilegeEffectiveness(EffectivenessKind.ViaRole, Role: role, InheritsAutomatically: context.InheritsAutomatically);
            }
        }

        return PrivilegeEffectiveness.NotEffective;
    }

    /// <summary>Every role the principal belongs to, directly or through another role, each once even when membership cycles.</summary>
    public static IReadOnlyList<string> RoleClosure(PrincipalRef principal, IEnumerable<PrincipalInfo> principals)
    {
        var membership = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
        foreach (var info in principals)
        {
            membership.TryAdd(info.Ref.Name, info.MemberOf);
        }

        var visited = new HashSet<string>(StringComparer.Ordinal) { principal.Name };
        var frontier = new Stack<string>(membership.TryGetValue(principal.Name, out var direct) ? direct : []);
        var closure = new List<string>();
        while (frontier.TryPop(out var role))
        {
            if (!visited.Add(role))
            {
                continue;
            }

            closure.Add(role);
            if (membership.TryGetValue(role, out var parents))
            {
                foreach (var parent in parents)
                {
                    frontier.Push(parent);
                }
            }
        }

        return closure;
    }

    private static PrivilegeScope? CascadingAncestor(string privilege, PrivilegeScope scope, IReadOnlySet<PrincipalGrantKey> grants, Func<PrivilegeScope, PrivilegeScope, bool> cascades)
    {
        for (var ancestor = scope.Parent; ancestor is not null; ancestor = ancestor.Parent)
        {
            if (grants.Contains(new PrincipalGrantKey(privilege, ancestor)) && cascades(ancestor, scope))
            {
                return ancestor;
            }
        }

        return null;
    }
}
