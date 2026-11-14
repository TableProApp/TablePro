using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

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
        app.Click(app.Find("ExportConnectionsButton"), () => FileDialog(app) is not null);
        SaveInFileDialog(app, file);
        // The bar says what happened, and a wait that gives up keeps a shot of it.
        app.FindByNamePrefix("Exported 2 connections.", app.Find("HomeMessageBar"));
        Assert.True(File.Exists(file), "The export wrote no file.");
        app.Screenshot("79-connections-exported");
        var text = File.ReadAllText(file);
        Assert.Contains("Chinook (Sample) (Copy)", text, StringComparison.Ordinal);
    }

    // The system's Save As dialog is Win32, as the Open dialog is: Enter saves to the path typed in its File name box.
    private static void SaveInFileDialog(AppSession app, string path)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var dialog = Retry.WhileNull(() => FileDialog(app), AppSession.Wait, throwOnTimeout: false).Result
                ?? throw new InvalidOperationException("The Save As dialog did not appear.");
            var name = Retry.WhileNull(
                    () => dialog.FindFirstDescendant(condition => condition.ByControlType(ControlType.Edit)
                        .And(condition.ByAutomationId("1001").Or(condition.ByName("File name:")))),
                    AppSession.Wait,
                    throwOnTimeout: false).Result
                ?? throw new InvalidOperationException("The Save As dialog has no File name box.");
            dialog.SetForeground();
            name.Focus();
            name.AsTextBox().Text = path;
            Keyboard.Type(VirtualKeyShort.RETURN);
            if (Retry.WhileFalse(() => FileDialog(app) is null, TimeSpan.FromSeconds(5), throwOnTimeout: false).Success)
            {
                return;
            }
        }

        // Left open, the dialog would keep the window from closing after the test.
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        throw new InvalidOperationException("The Save As dialog did not take the path.");
    }
}
