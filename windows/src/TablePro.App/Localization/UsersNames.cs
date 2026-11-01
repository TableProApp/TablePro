using TablePro.Core.Principals;

namespace TablePro.App.Localization;

/// <summary>
/// The Users and Roles editor's text for values Core describes in English: principal kinds and stages, privilege
/// categories, role attributes, scope summaries and why a privilege is held.
/// </summary>
internal static class UsersNames
{
    public static string KindTitle(bool isRole) => isRole ? Strings.Get("Users/KindRole") : Strings.Get("Users/KindUser");

    public static string? StageDescription(PrincipalStage stage) => stage switch
    {
        PrincipalStage.Created => Strings.Get("Users/StageCreated"),
        PrincipalStage.Modified => Strings.Get("Users/StageModified"),
        PrincipalStage.Dropped => Strings.Get("Users/StageDropped"),
        _ => null,
    };

    // An engine-defined category arrives with its own key as its title, which stays as the engine spells it.
    public static string CategoryTitle(PrivilegeCategory category) => category.Key switch
    {
        PrivilegeCategoryKeys.Data => Strings.Get("Users/CategoryData"),
        PrivilegeCategoryKeys.Structure => Strings.Get("Users/CategoryStructure"),
        PrivilegeCategoryKeys.Administration => Strings.Get("Users/CategoryAdministration"),
        PrivilegeCategoryKeys.Dynamic => Strings.Get("Users/CategoryDynamic"),
        "other" => Strings.Get("Users/CategoryOther"),
        _ => category.Title,
    };

    public static string AttributeLabel(PrincipalAttribute attribute) => attribute.Key switch
    {
        "SUPERUSER" => Strings.Get("Users/AttributeSuperuser"),
        "CREATEDB" => Strings.Get("Users/AttributeCreateDatabases"),
        "CREATEROLE" => Strings.Get("Users/AttributeCreateRoles"),
        "REPLICATION" => Strings.Get("Users/AttributeReplication"),
        "BYPASSRLS" => Strings.Get("Users/AttributeBypassRls"),
        "INHERIT" => Strings.Get("Users/AttributeInherit"),
        _ => attribute.Label,
    };

    public static string AttributeSummary(PrincipalInfo info) =>
        string.Join(", ", info.Attributes.Where(a => a.IsEnabled).Select(AttributeLabel));

    public static string? EffectivenessDescription(PrivilegeEffectiveness effect) => effect.Kind switch
    {
        EffectivenessKind.ViaScope => Strings.Format("Users/GrantedOn", effect.Scope!.DisplayName),
        EffectivenessKind.ViaRole => Strings.Format("Users/InheritedFrom", effect.Role),
        _ => null,
    };

    public static string? EffectivenessDetail(PrivilegeEffectiveness effect) => effect.Kind == EffectivenessKind.ViaRole
        ? effect.InheritsAutomatically ? Strings.Get("Users/InheritedAutomatically") : Strings.Format("Users/AvailableAfterSetRole", effect.Role)
        : null;

    public static string ScopeSummaryText(ScopeSummary summary)
    {
        switch (summary)
        {
            case ScopeSummary.NotGrantable:
                return string.Empty;
            case ScopeSummary.NoneGranted:
                return Strings.Get("Users/ScopeSummaryNone");
            case ScopeSummary.AllGranted all:
                return Strings.Format("Users/ScopeSummaryAll", all.Count);
            case ScopeSummary.SomeGranted some:
                var text = string.Join(", ", some.Names);
                if (some.Overflow > 0)
                {
                    text = Strings.Format("Users/ScopeSummaryOverflow", text, some.Overflow);
                }

                return some.HasGrantOption ? Strings.Format("Users/ScopeSummaryGrantable", text) : text;
            case ScopeSummary.DescendantsOnly descendants:
                return Strings.Plural("Users/ScopeSummaryGrantsInside", descendants.Count);
            case ScopeSummary.BrowsingRestricted restricted:
                return restricted.Direct.Count == 0 ? Strings.Get("Users/ScopeSummaryConnectToBrowse") : string.Join(", ", restricted.Direct);
            default:
                return summary.Text;
        }
    }
}
