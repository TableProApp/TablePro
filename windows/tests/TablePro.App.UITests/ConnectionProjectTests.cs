using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    private const string Sample = "Chinook (Sample),";
    private const string Copy = "Chinook (Sample) (Copy),";

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheConnectionsPageShowsOneProjectAndItsSearchStaysInside(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Find("HomeItem").AsListBoxItem().Select();
        app.Front();
        app.RightClick(
            app.FindByNamePrefix(Sample, app.Find("ConnectionTree")),
            () => app.TryFindMenuItem("Duplicate") is not null);
        app.FindMenuItem("Duplicate").Patterns.Invoke.Pattern.Invoke();
        var form = app.WaitForWindow("Edit connection");
        app.Find("CancelButton", form).AsButton().Invoke();
        app.WaitForClose("Edit connection");
        app.FindByNamePrefix(Copy, app.Find("ConnectionTree"));

        // A new project becomes the active one and starts empty.
        NewProject(app, "Acme");
        Assert.Equal("No connections in Acme", app.Find("EmptyProjectTitle").Name);
        SwitchProject(app, "All connections");
        MoveToProject(app, Copy, "Acme");
        NewProject(app, "Globex");
        SwitchProject(app, "All connections");
        MoveToProject(app, Sample, "Globex");

        OpenSwitcher(app);
        app.FindMenuItem("Manage projects...");
        app.Screenshot("185-project-switcher");
        app.Click(app.FindMenuItem("Acme"), () => IsActive(app, "Acme"));
        app.FindByNamePrefix(Copy, app.Find("ConnectionTree"));
        Assert.True(Absent(app, Sample), "A connection of another project showed in Acme.");
        app.Screenshot("186-project-home");

        SwitchProject(app, "Globex");
        app.FindByNamePrefix(Sample, app.Find("ConnectionTree"));
        Assert.True(Absent(app, Copy), "A connection of another project showed in Globex.");
        var search = app.Find("LibrarySearch").FindFirstDescendant(condition => condition.ByControlType(ControlType.Edit));
        Assert.NotNull(search);
        app.Click(search);
        Keyboard.Type("Copy");
        app.Click(app.Find("SearchAllConnectionsButton"), () => IsActive(app, "All connections"));
        app.FindByNamePrefix(Copy, app.Find("ConnectionTree"));
    }

    private static void OpenSwitcher(AppSession app) =>
        app.Click(app.Find("ProjectSwitcher"), () => app.TryFindMenuItem("New project...") is not null);

    private static bool IsActive(AppSession app, string project) =>
        AppSession.Holds(() => app.TryFind("ProjectSwitcher")?.Name == "Project: " + project);

    private static void NewProject(AppSession app, string name)
    {
        OpenSwitcher(app);
        app.FindMenuItem("New project...").Patterns.Invoke.Pattern.Invoke();
        app.Find("NameDialogBox").AsTextBox().Text = name;
        app.PressDialogButton("Create");
        Assert.True(
            Retry.WhileFalse(() => IsActive(app, name), AppSession.Wait, throwOnTimeout: false).Success,
            $"The new project {name} did not become the active one.");
        // The panel itself has no automation peer.
        app.Find("EmptyProjectTitle");
    }

    private static void SwitchProject(AppSession app, string name)
    {
        OpenSwitcher(app);
        app.Click(app.FindMenuItem(name), () => IsActive(app, name));
    }

    private static void MoveToProject(AppSession app, string row, string project)
    {
        app.RightClick(
            app.FindByNamePrefix(row, app.Find("ConnectionTree")),
            () => app.TryFindMenuItem("Move to project") is not null);
        app.OpenSubmenu("Move to project", project).Patterns.Invoke.Pattern.Invoke();
    }

    // The tree is built again after a switch, so the row is looked for until the page settles without it.
    private static bool Absent(AppSession app, string prefix) =>
        Retry.WhileTrue(
            () => AppSession.Holds(() => app.Find("ConnectionTree").FindAllDescendants().Any(element =>
                element.Properties.Name.TryGetValue(out var name) && name.StartsWith(prefix, StringComparison.Ordinal))),
            TimeSpan.FromSeconds(10),
            throwOnTimeout: false).Success;
}
