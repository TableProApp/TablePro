using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ADuplicateOpensTheFormOnTheCopyAndAnExportWritesTheFile(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Find("HomeItem").AsListBoxItem().Select();
        var tree = app.Find("ConnectionTree");

        app.Front();
        app.RightClick(
            app.FindByNamePrefix("Chinook (Sample),", tree),
            () => app.TryFindMenuItem("Duplicate") is not null);
        app.FindMenuItem("Duplicate").Patterns.Invoke.Pattern.Invoke();
        var form = app.WaitForWindow("Edit connection");
        Assert.Equal("Chinook (Sample) (Copy)", app.Find("NameBox", form).AsTextBox().Text);
        app.Screenshot("78-duplicate-connection", form);
        app.Find("CancelButton", form).AsButton().Invoke();
        app.WaitForClose("Edit connection");
        app.FindByNamePrefix("Chinook (Sample) (Copy),", tree);

        var file = Path.Combine(app.DataFolder, "exported-connections.json");
        app.Click(app.Find("ExportConnectionsButton"), () => app.HasWindow("Save As"));
        var save = app.WaitForWindow("Save As");
        var name = Retry.WhileNull(
                () => save.FindFirstDescendant(condition => condition.ByControlType(ControlType.Edit).And(condition.ByName("File name:"))),
                AppSession.Wait)
            .Result ?? throw new InvalidOperationException("The Save As dialog has no File name box.");
        name.AsTextBox().Text = file;
        app.Find("1", save).AsButton().Invoke();
        Assert.True(Retry.WhileFalse(() => File.Exists(file), AppSession.Wait).Success, "The export wrote no file.");
        app.FindByNamePrefix("Exported 2 connections.", app.Find("HomeMessageBar"));
        app.Screenshot("79-connections-exported");
        var text = File.ReadAllText(file);
        Assert.Contains("Chinook (Sample) (Copy)", text, StringComparison.Ordinal);
    }
}
