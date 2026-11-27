using System.Globalization;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using TablePro.Testing;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ACellsValueFiltersTheTableAndTheTableOpensAgainWithIt(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.OpenSampleFromHelp();
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
        app.OpenSampleFromHelp();
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
        app.OpenSampleFromHelp();
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
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows PostgreSQL fixture.");
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "PostgreSQL schemas";
        app.Find("HostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("PortBox", form).AsTextBox().Text = SshTestEnvironment.DatabasePort.ToString(CultureInfo.InvariantCulture);
        app.Find("UserBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("DatabaseBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("PasswordInput", form).Patterns.Value.Pattern.SetValue(SshTestEnvironment.DatabasePassword);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        var tree = app.Find("ObjectTree");
        app.FindByName("ssh_proof", tree);

        // The dialog shows the options PostgreSQL names for a new database, each starting on the server's own.
        app.Click(app.Find("DatabaseMenu"), () => app.TryFindMenuItem("New database...") is not null);
        app.Click(app.FindMenuItem("New database..."), () => app.TryFind("CatalogName") is not null);
        Assert.NotNull(app.TryFind("CatalogOwner"));
        Assert.NotNull(app.TryFind("CatalogEncoding"));
        app.Find("CatalogName").AsTextBox().Text = "tablepro_shop";
        Assert.Equal(
            "CREATE DATABASE \"tablepro_shop\";",
            AppSession.WaitForText(app.Find("CatalogStatements"), text => text.Length > 0));
        app.Screenshot("106-new-database");
        app.CloseDialog();
        Assert.True(Retry.WhileTrue(() => app.TryFind("CatalogName") is not null, AppSession.Wait, throwOnTimeout: false).Success);

        app.Click(app.Find("DatabaseMenu"), () => app.TryFindMenuItem("New schema...") is not null);
        app.Click(app.FindMenuItem("New schema..."), () => app.TryFind("CatalogName") is not null);
        app.Find("CatalogName").AsTextBox().Text = "tablepro_sales";
        Assert.Equal(
            "CREATE SCHEMA \"tablepro_sales\";",
            AppSession.WaitForText(app.Find("CatalogStatements"), text => text.Length > 0));
        app.Screenshot("107-new-schema");
        app.PressDialogButton("Create");
        var sales = Retry.WhileNull(
                () => tree.FindFirstDescendant(condition => condition.ByName("tablepro_sales")),
                AppSession.Wait,
                throwOnTimeout: false).Result
            ?? throw new InvalidOperationException("The new schema did not show.");

        app.RightClick(sales, () => app.TryFindMenuItem("Drop schema “tablepro_sales”...") is not null);
        app.Click(app.FindMenuItem("Drop schema “tablepro_sales”..."), () => app.TryFind("CatalogStatements") is not null);
        Assert.Equal("DROP SCHEMA \"tablepro_sales\";", app.Find("CatalogStatements").Name);
        app.Screenshot("108-drop-schema");
        app.PressDialogButton("Drop");
        Assert.True(Retry.WhileFalse(
            () => tree.FindFirstDescendant(condition => condition.ByName("tablepro_sales")) is null,
            AppSession.Wait,
            throwOnTimeout: false).Success);
    }
}
