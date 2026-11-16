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
    public void ACellsValueFiltersTheTableAndTheTableOpensAgainWithIt(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var tree = app.Find("ObjectTree");
        app.Click(app.FindByName("Genre", tree), () => app.TryFind("TableStatus") is not null);
        Assert.True(ShowsRows(app.Find("TableStatus"), 25));
        var grid = app.Find("ResultsGrid");
        Assert.Equal("Rock", app.WaitForCell(grid, 0, 1, value => value == "Rock"));

        app.RightClick(CellOf(grid, 0, 1), () => app.TryFindMenuItem("Filter") is not null);
        var equal = app.OpenSubmenu("Filter", "Name = “Rock”");
        Assert.NotNull(app.TryFindMenuItem("Name != “Rock”"));
        app.Screenshot("98-filter-by-cell-menu");
        app.Click(equal);
        Assert.True(ShowsRows(app.Find("TableStatus"), 1));
        Assert.Equal("Rock", app.Find("FilterValue0").AsTextBox().Text);
        app.Screenshot("99-filter-by-cell");

        var tabs = app.Find("Tabs");
        bool Open() => tabs.FindFirstDescendant(condition =>
            condition.ByControlType(ControlType.TabItem).And(condition.ByName("Genre"))) is not null;
        app.Chord(() => !Open(), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Click(app.FindByName("Genre", tree), () => app.TryFind("TableStatus") is not null);

        Assert.True(ShowsRows(app.Find("TableStatus"), 1));
        Assert.Equal("Rock", app.Find("FilterValue0").AsTextBox().Text);
        app.Screenshot("100-filter-kept-for-table");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATableIsEmptiedAndDroppedAfterAQuestionShowingItsStatement(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var tree = app.Find("ObjectTree");

        // Track's foreign key points at Genre, so emptying it is refused before anything is asked.
        app.RightClick(app.FindByName("Genre", tree), () => app.TryFindMenuItem("Truncate...") is not null);
        app.Click(
            app.FindMenuItem("Truncate..."),
            () => app.Window.FindFirstDescendant(condition => condition.ByName("Cannot truncate table")) is not null);
        app.Screenshot("101-truncate-refused");
        app.CloseDialog();

        app.RightClick(app.FindByName("PlaylistTrack", tree), () => app.TryFindMenuItem("Truncate...") is not null);
        app.Click(app.FindMenuItem("Truncate..."), () => app.TryFind("CatalogStatements") is not null);
        Assert.Equal("DELETE FROM \"PlaylistTrack\";", app.Find("CatalogStatements").Name);
        app.Screenshot("102-truncate-question");
        app.PressDialogButton("Truncate");
        Assert.True(Retry.WhileTrue(() => app.TryFind("CatalogStatements") is not null, AppSession.Wait, throwOnTimeout: false).Success);
        app.Click(app.FindByName("PlaylistTrack", tree), () => app.TryFind("TableStatus") is not null);
        Assert.True(ShowsRows(app.Find("TableStatus"), 0));

        app.RightClick(app.FindByName("PlaylistTrack", tree), () => app.TryFindMenuItem("Drop...") is not null);
        app.Click(app.FindMenuItem("Drop..."), () => app.TryFind("CatalogStatements") is not null);
        Assert.Equal("DROP TABLE \"PlaylistTrack\";", app.Find("CatalogStatements").Name);
        app.Screenshot("103-drop-question");
        app.PressDialogButton("Drop");

        Assert.True(Retry.WhileFalse(
            () => tree.FindFirstDescendant(condition => condition.ByName("PlaylistTrack")) is null
                && app.TryFind("TableStatus") is null,
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("104-table-dropped");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AQueryResultExportsAsSqlInsert(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "SELECT GenreId, Name FROM Genre");
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: ", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 0, 1, value => value == "Rock");

        app.RightClick(CellOf(grid, 0, 1), () => app.TryFindMenuItem("Export results...") is not null);
        Assert.Null(app.TryFindMenuItem("Filter"));
        app.Click(app.FindMenuItem("Export results..."), () => app.TryFind("ExportFormats") is not null);
        var sqlInsert = app.FindByName("SQL INSERT", app.Find("ExportFormats"));
        app.Click(sqlInsert);
        app.Screenshot("105-export-result-as-sql-insert");
        app.CloseDialog();
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ASchemaIsCreatedAndDroppedFromTheDatabaseMenuAndItsRow(string theme)
    {
        using var app = AppSession.Launch(theme);
        var file = Path.Combine(app.DataFolder, "catalog.duckdb");
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_duckdb", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "Catalog";
        app.Click(app.Find("NewFileButton", form), () => SaveDialog(app, form) is not null, form);
        SaveInFileDialog(app, form, file);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        var tree = app.Find("ObjectTree");

        app.Click(app.Find("DatabaseMenu"), () => app.TryFindMenuItem("New schema...") is not null);
        app.Click(app.FindMenuItem("New schema..."), () => app.TryFind("CatalogName") is not null);
        app.Find("CatalogName").AsTextBox().Text = "sales";
        Assert.Equal(
            "CREATE SCHEMA \"sales\";",
            AppSession.WaitForText(app.Find("CatalogStatements"), text => text.Length > 0));
        app.Screenshot("106-new-schema");
        app.PressDialogButton("Create");
        var sales = Retry.WhileNull(
                () => tree.FindFirstDescendant(condition => condition.ByName("sales")),
                AppSession.Wait,
                throwOnTimeout: false).Result
            ?? throw new InvalidOperationException("The new schema did not show.");

        app.RightClick(sales, () => app.TryFindMenuItem("Drop schema “sales”...") is not null);
        app.Click(app.FindMenuItem("Drop schema “sales”..."), () => app.TryFind("CatalogStatements") is not null);
        Assert.Equal("DROP SCHEMA \"sales\";", app.Find("CatalogStatements").Name);
        app.Screenshot("107-drop-schema");
        app.PressDialogButton("Drop");
        Assert.True(Retry.WhileFalse(
            () => tree.FindFirstDescendant(condition => condition.ByName("sales")) is null,
            AppSession.Wait,
            throwOnTimeout: false).Success);
    }

    // The form owns its picker, so UI Automation lists it under the form, the app's window or the desktop.
    private static Window? SaveDialog(AppSession app, Window form) =>
        form.FindFirstChild(condition => condition.ByClassName("#32770"))?.AsWindow() ?? FileDialog(app);

    // The Save dialog's File name box is control 1001, and Enter saves to the path typed there.
    private static void SaveInFileDialog(AppSession app, Window form, string path)
    {
        var dialog = Retry.WhileNull(() => SaveDialog(app, form), AppSession.Wait, throwOnTimeout: false).Result
            ?? throw new InvalidOperationException("The Save dialog did not appear.");
        var name = Retry.WhileNull(
                () => dialog.FindFirstDescendant(condition =>
                    condition.ByAutomationId("1001").And(condition.ByControlType(ControlType.Edit))),
                AppSession.Wait,
                throwOnTimeout: false).Result
            ?? throw new InvalidOperationException("The Save dialog has no File name box.");
        // The Save dialog keeps its suggested name when the box's value is set without typing, so the path is typed.
        dialog.SetForeground();
        name.Focus();
        Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
        Keyboard.Type(path);
        if (!Retry.WhileFalse(() => name.AsTextBox().Text == path, AppSession.Wait, throwOnTimeout: false).Success)
        {
            throw new InvalidOperationException("The Save dialog did not take the path typed.");
        }

        Keyboard.Type(VirtualKeyShort.RETURN);
        if (!Retry.WhileFalse(() => SaveDialog(app, form) is null, AppSession.Wait, throwOnTimeout: false).Success)
        {
            throw new InvalidOperationException("The Save dialog did not take the path.");
        }
    }
}
