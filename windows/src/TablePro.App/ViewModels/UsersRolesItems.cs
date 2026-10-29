using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using TablePro.Core.Principals;

namespace TablePro.App.ViewModels;

public enum UsersRolesSegment
{
    Privileges,
    Attributes,
}

public enum ScopeViewMode
{
    /// <summary>The server's databases, browsed level by level.</summary>
    All,

    /// <summary>Only the objects the selected principal holds something on, with their parents.</summary>
    Granted,
}

/// <summary>A row of the principal list, updated in place so the list keeps its selection while edits are staged.</summary>
public sealed partial class PrincipalRowItem : ObservableObject
{
    public PrincipalRowItem(PrincipalRow row, PrincipalRef? renamedTo) => Update(row, renamedTo);

    public PrincipalRef Ref { get; private set; } = new(string.Empty);

    [ObservableProperty]
    public partial string Title { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string Glyph { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string Summary { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial Visibility SummaryVisibility { get; private set; }

    [ObservableProperty]
    public partial string StageGlyph { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string StageDescription { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial Visibility StageVisibility { get; private set; }

    /// <summary>A row staged for dropping is dimmed rather than removed, so the drop can be seen and undone.</summary>
    [ObservableProperty]
    public partial double TitleOpacity { get; private set; } = 1;

    [ObservableProperty]
    public partial string KindTitle { get; private set; } = string.Empty;

    public PrincipalStage Stage { get; private set; }

    public bool IsRole { get; private set; }

    public void Update(PrincipalRow row, PrincipalRef? renamedTo)
    {
        Ref = row.Ref;
        Stage = row.Stage;
        IsRole = row.Info.IsRole;
        Title = renamedTo is null ? row.DisplayName : $"{row.DisplayName} → {renamedTo.DisplayName}";
        Glyph = row.Info.IsRole ? "" : "";
        Summary = UsersNames.AttributeSummary(row.Info);
        SummaryVisibility = Summary.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        StageGlyph = row.Stage switch
        {
            PrincipalStage.Created => "",
            PrincipalStage.Modified => "",
            PrincipalStage.Dropped => "",
            _ => string.Empty,
        };
        StageDescription = UsersNames.StageDescription(row.Stage) ?? string.Empty;
        StageVisibility = row.Stage == PrincipalStage.Unchanged ? Visibility.Collapsed : Visibility.Visible;
        TitleOpacity = row.Stage == PrincipalStage.Dropped ? 0.5 : 1;
        KindTitle = UsersNames.KindTitle(row.Info.IsRole);
    }
}

/// <summary>Whether a scope's children can be listed.</summary>
public enum ScopeChildren
{
    Available,

    /// <summary>A database other than the connected one, on an engine that reads below database level only where it is connected.</summary>
    RestrictedToCurrentDatabase,
    None,
}

/// <summary>A node of the privilege scope tree. Children load the first time it expands.</summary>
public sealed partial class ScopeNodeItem : ObservableObject
{
    public ScopeNodeItem(PrivilegeScope scope, ScopeChildren children)
    {
        Scope = scope;
        ChildrenAvailability = children;
        HasUnrealizedChildren = children == ScopeChildren.Available;
    }

    public PrivilegeScope Scope { get; }

    public ScopeChildren ChildrenAvailability { get; }

    public string Title => Scope.DisplayName;

    public string Glyph => Scope.Level switch
    {
        PrivilegeLevel.Server => "",
        PrivilegeLevel.Database => "",
        PrivilegeLevel.Schema => "",
        PrivilegeLevel.Table => "",
        _ => "",
    };

    public ObservableCollection<ScopeNodeItem> Children { get; } = [];

    [ObservableProperty]
    public partial bool HasUnrealizedChildren { get; set; }

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string Summary { get; set; } = string.Empty;

    public bool IsLoaded { get; set; }

    /// <summary>Gives the node fixed children, so it never loads; the Granted view and search results are built this way.</summary>
    public void SetChildren(IEnumerable<ScopeNodeItem> children)
    {
        Children.Clear();
        foreach (var child in children)
        {
            Children.Add(child);
        }

        IsLoaded = true;
        HasUnrealizedChildren = false;
    }

    public IEnumerable<ScopeNodeItem> SelfAndDescendants()
    {
        yield return this;
        foreach (var child in Children)
        {
            foreach (var node in child.SelfAndDescendants())
            {
                yield return node;
            }
        }
    }
}
