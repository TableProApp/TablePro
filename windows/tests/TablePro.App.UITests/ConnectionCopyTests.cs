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
    public void ADuplicateOpensTheFormOnTheCopyAndExportAsksWhereToSave(string theme)
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

        // The system's Save As dialog is not driven here; the core's and the interop's tests write the file.
        app.Click(app.Find("ExportConnectionsButton"), () => FileDialog(app) is not null);
        var dialog = FileDialog(app) ?? throw new InvalidOperationException("The Save As dialog did not appear.");
        dialog.SetForeground();
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        Assert.True(
            Retry.WhileFalse(() => FileDialog(app) is null, AppSession.Wait, throwOnTimeout: false).Success,
            "The Save As dialog stayed open.");
    }
}
