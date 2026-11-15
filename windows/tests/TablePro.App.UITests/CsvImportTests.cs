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
    public void ACsvFileImportsIntoATableByItsColumnMapping(string theme)
    {
        using var app = AppSession.Launch(theme);
        // Name matches the Genre table's column and Notes none, so GenreId is left to SQLite's rowid.
        var file = Path.Combine(app.DataFolder, "genres.csv");
        File.WriteAllText(file, "Name,Notes\r\nTablePro Jazz,first\r\nTablePro Folk,second\r\n");

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var tree = app.Find("ObjectTree");
        app.RightClick(app.FindByName("Genre", tree), () => app.TryFindMenuItem("Import CSV...") is not null);
        // A click, not UIA's Invoke, which would wait on the picker the item opens.
        app.Click(app.FindMenuItem("Import CSV..."));
        OpenInFileDialog(app, file);

        Assert.Equal(
            "2 fields, 2 rows.",
            AppSession.WaitForText(app.Find("ImportCsvSummary"), text => text == "2 fields, 2 rows."));
        Assert.Equal("From genres.csv", app.Find("ImportCsvFile").Name);
        Assert.Equal("Skip", app.Find("ImportCsvField0").AsComboBox().SelectedItem?.Text);
        Assert.Equal("Name (TablePro Jazz)", app.Find("ImportCsvField1").AsComboBox().SelectedItem?.Text);
        Assert.Equal("TablePro Jazz · TablePro Folk", app.Find("ImportCsvNote1").Name);
        Assert.True(Retry.WhileFalse(
            () => app.Find("PrimaryButton").IsEnabled,
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("75-csv-import-dialog");

        // Safe Mode may ask first, listing the INSERT the rows go out as.
        app.PressDialogButton();
        var review = Retry.WhileNull(
            () => app.TryFind("ImportReviewStatements"),
            TimeSpan.FromSeconds(3),
            throwOnTimeout: false).Result;
        if (review is not null)
        {
            Assert.Contains("INSERT", review.Name, StringComparison.OrdinalIgnoreCase);
            app.PressDialogButton();
        }

        Assert.True(Retry.WhileTrue(
            () => app.TryFind("ImportCsvSummary") is not null || app.TryFind("ImportReviewStatements") is not null,
            AppSession.Wait,
            throwOnTimeout: false).Success);

        app.Click(app.FindByName("Genre", tree), () => app.TryFind("TableStatus") is not null);
        var status = app.Find("TableStatus");
        // The tab can read its page before the import's rows land, so it reads it again until they show.
        var shown = ShowsRows(status, 27);
        for (var attempt = 0; attempt < 3 && !shown; attempt++)
        {
            app.Find("RefreshTableButton").AsButton().Invoke();
            shown = ShowsRows(status, 27);
        }

        Assert.True(shown, status.Properties.Name.ValueOrDefault);
        var grid = app.Find("ResultsGrid");
        Assert.Equal("TablePro Jazz", app.WaitForCell(grid, 25, 1, value => value == "TablePro Jazz"));
        Assert.Equal("TablePro Folk", app.WaitForCell(grid, 26, 1, value => value == "TablePro Folk"));
        app.Screenshot("76-csv-imported");
    }

    private static bool ShowsRows(AutomationElement status, int rows) =>
        Retry.WhileFalse(
            () => (status.Properties.Name.ValueOrDefault ?? string.Empty)
                .StartsWith($"Rows: {rows} ", StringComparison.Ordinal),
            TimeSpan.FromSeconds(10),
            throwOnTimeout: false).Success;

    // The system's Open dialog is Win32: control 1148 is its File name box, and Enter opens the path typed there.
    private static void OpenInFileDialog(AppSession app, string path)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var dialog = Retry.WhileNull(() => FileDialog(app), AppSession.Wait, throwOnTimeout: false).Result
                ?? throw new InvalidOperationException("The Open dialog did not appear.");
            var name = Retry.WhileNull(
                    () => dialog.FindFirstDescendant(condition =>
                        condition.ByAutomationId("1148").And(condition.ByControlType(ControlType.Edit))),
                    AppSession.Wait,
                    throwOnTimeout: false).Result
                ?? throw new InvalidOperationException("The Open dialog has no File name box.");
            dialog.SetForeground();
            name.Focus();
            name.AsTextBox().Text = path;
            Keyboard.Type(VirtualKeyShort.RETURN);
            if (Retry.WhileFalse(() => FileDialog(app) is null, TimeSpan.FromSeconds(5), throwOnTimeout: false).Success)
            {
                return;
            }
        }

        throw new InvalidOperationException("The Open dialog did not take the file.");
    }

    // The app's window owns the dialog, so UI Automation may list it under that window or under the desktop.
    private static Window? FileDialog(AppSession app)
    {
        var owned = app.Window.FindFirstChild(condition => condition.ByClassName("#32770"));
        if (owned is not null)
        {
            return owned.AsWindow();
        }

        var process = app.Window.Properties.ProcessId.Value;
        return app.Window.Automation.GetDesktop()
            .FindFirstChild(condition => condition.ByClassName("#32770").And(condition.ByProcessId(process)))
            ?.AsWindow();
    }
}
