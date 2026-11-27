using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The project choices, built the same for the Connections page's switcher and for File, Project.
internal static class ProjectMenus
{
    // All connections first, then each project, the active one checked; then New project and Manage projects.
    public static void Fill(
        IList<MenuFlyoutItemBase> items,
        Workbench workbench,
        string idPrefix,
        Action newProject,
        Action manageProjects)
    {
        items.Clear();
        var active = LibraryScope.Resolve(workbench.ActiveProject, workbench.Projects);
        items.Add(Choice(workbench, null, Strings.Get("ProjectAllConnections"), active, idPrefix + "ProjectChoiceAll"));
        foreach (var project in workbench.Projects)
        {
            items.Add(Choice(workbench, project.Id, project.Name, active, null));
        }

        items.Add(new MenuFlyoutSeparator());
        var create = new MenuFlyoutItem { Text = Strings.Get("ProjectNew"), Icon = new SymbolIcon(Symbol.Add) };
        AutomationProperties.SetAutomationId(create, idPrefix + "ProjectNewItem");
        create.Click += (_, _) => newProject();
        items.Add(create);
        // With no project there is nothing to rename, reorder or delete.
        if (workbench.Projects.Count > 0)
        {
            var manage = new MenuFlyoutItem { Text = Strings.Get("ProjectManage") };
            AutomationProperties.SetAutomationId(manage, idPrefix + "ProjectManageItem");
            manage.Click += (_, _) => manageProjects();
            items.Add(manage);
        }
    }

    // No project first, then each project; the one every moved item is in already is disabled.
    public static MenuFlyoutSubItem MoveMenu(
        IReadOnlyList<ConnectionProject> projects,
        IEnumerable<Guid?> current,
        Func<Guid?, Task> move)
    {
        var menu = new MenuFlyoutSubItem { Text = Strings.Get("MenuMoveToProject"), Icon = new SymbolIcon(Symbol.Library) };
        AutomationProperties.SetAutomationId(menu, "MoveToProjectMenu");
        foreach (var choice in LibraryScope.Choices(projects, current))
        {
            var entry = new MenuFlyoutItem
            {
                Text = choice.Name ?? Strings.Get("MenuNoProject"),
                IsEnabled = !choice.IsCurrent,
            };
            var target = choice.Id;
            entry.Click += async (_, _) => await move(target).ConfigureAwait(true);
            menu.Items.Add(entry);
        }

        return menu;
    }

    private static RadioMenuFlyoutItem Choice(
        Workbench workbench, Guid? id, string name, Guid? active, string? automationId)
    {
        var choice = new RadioMenuFlyoutItem
        {
            Text = name,
            GroupName = "ActiveProject",
            IsChecked = id == active,
        };
        if (automationId is not null)
        {
            AutomationProperties.SetAutomationId(choice, automationId);
        }

        choice.Click += (_, _) => workbench.SetActiveProject(id);
        return choice;
    }
}
