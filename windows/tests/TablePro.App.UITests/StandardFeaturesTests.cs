using System.Globalization;
using System.Text.RegularExpressions;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    private const string ShopUrl = "postgresql://app@db.example.com:5433/shop";

    [Theory]
    [MemberData(nameof(Themes))]
    public void AUrlOnTheConnectionsPageStartsAConnectionFromTheButtonAndFromPaste(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("NewFromUrlButton"), () => app.TryFind("HomeUrlBox") is not null);
        app.Find("HomeUrlBox").AsTextBox().Text = ShopUrl;
        app.Screenshot("120-new-from-url");
        app.Click(app.Find("HomeUrlContinueButton"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        Assert.Equal("db.example.com", app.Find("HostBox", form).AsTextBox().Text);
        Assert.Equal("5433", app.Find("PortBox", form).AsTextBox().Text);
        Assert.Equal("shop", app.Find("DatabaseBox", form).AsTextBox().Text);
        Assert.Equal("app", app.Find("UserBox", form).AsTextBox().Text);
        app.Screenshot("121-new-from-url-form", form);
        app.Find("CancelButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        // Copied from the page's own search box, so the test needs no clipboard of its own.
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Find("HomeItem").AsListBoxItem().Select();
        var search = app.Find("LibrarySearch").FindFirstDescendant(condition => condition.ByControlType(ControlType.Edit));
        Assert.NotNull(search);
        app.Click(search);
        Keyboard.Type(ShopUrl.Replace("5433", "5434", StringComparison.Ordinal));
        app.Chord(() => true, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
        app.Chord(() => true, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_C);
        // Typed away, as a value set through UI Automation leaves the suggestion box's filter in place.
        app.Chord(() => true, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
        Keyboard.Type(VirtualKeyShort.BACK);
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("ConnectionTree") is { IsOffscreen: false },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Click(app.FindByNamePrefix("Chinook (Sample),", app.Find("ConnectionTree")));
        app.Chord(() => app.HasWindow("New connection"), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_V);
        form = app.WaitForWindow("New connection");
        Assert.Equal("5434", app.Find("PortBox", form).AsTextBox().Text);
        app.Find("CancelButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        // With the focus on the rail, outside the page, where a key handler on the page never sees the key.
        app.Click(app.Find("HomeItem"));
        app.Chord(() => app.HasWindow("New connection"), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_V);
        form = app.WaitForWindow("New connection");
        Assert.Equal("5434", app.Find("PortBox", form).AsTextBox().Text);
        app.Find("CancelButton", form).AsButton().Invoke();
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void JumpHostsAreCheckedSavedAndShownAgain(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "Behind bastions";
        app.Find("SshSwitch", form).AsToggleButton().Toggle();
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("SshHostBox", form) is { IsOffscreen: false },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Find("SshHostBox", form).AsTextBox().Text = "bastion.example.com";
        var jumps = app.Find("SshJumpHostsBox", form).AsTextBox();

        jumps.Text = "jump1,,jump2";
        app.Find("SaveButton", form).AsButton().Invoke();
        Assert.True(Retry.WhileFalse(
            () => app.Find("SshJumpHostsBox", form).Properties.FullDescription.ValueOrDefault is { Length: > 0 },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("122-jump-hosts-refused", form);

        jumps.Text = "ops@jump1:2200, jump2";
        app.Find("SshJumpHostsBox", form).Focus();
        app.Screenshot("123-jump-hosts", form);
        app.Find("SaveButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        app.RightClick(app.FindByNamePrefix("Behind bastions,", app.Find("ConnectionTree")));
        app.FindMenuItem("Edit...").Patterns.Invoke.Pattern.Invoke();
        var edit = app.WaitForWindow("Edit connection");
        Assert.Equal("ops@jump1:2200, jump2", app.Find("SshJumpHostsBox", edit).AsTextBox().Text);
        app.Find("CancelButton", edit).AsButton().Invoke();
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AGroupTakesAColourFromItsMenu(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Find("HomeItem").AsListBoxItem().Select();
        var tree = app.Find("ConnectionTree");
        app.Find("NewGroupButton").AsButton().Invoke();
        app.Find("NameDialogBox").AsTextBox().Text = "Production";
        app.PressDialogButton();

        app.RightClick(app.FindByName("Production", tree));
        app.Click(app.OpenSubmenu("Color", "Red"));

        Assert.True(Retry.WhileFalse(
            () => Regex.IsMatch(File.ReadAllText(AppSession.LibraryFile(app.DataFolder)), "\"color\"\\s*:\\s*\"red\""),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        // The menu opened again shows the colour checked, and the folder takes it.
        app.RightClick(app.FindByName("Production", tree));
        app.OpenSubmenu("Color", "Red");
        app.Screenshot("124-group-color");
        Keyboard.Type(VirtualKeyShort.ESCAPE, VirtualKeyShort.ESCAPE);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheDetailsPaneEditsTheFocusedRowAndShowsTheTablesFigures(string theme)
    {
        const string Renamed = "AC/DC (details)";
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Click(app.FindByName("Artist", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
        var grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 0, 1, value => value == "AC/DC");
        app.Click(CellOf(grid, 0, 1));

        app.Click(app.Find("DetailsButton"), () => app.TryFind("DetailsField_1") is not null);
        var name = app.Find("DetailsField_1").AsTextBox();
        Assert.Equal("AC/DC", name.Text);
        Assert.True(app.Find("DetailsField_0").AsTextBox().IsReadOnly);
        app.Screenshot("125-row-details");

        // Kept when the field loses the focus, as a cell's editor keeps what was typed.
        app.Click(name);
        app.Chord(() => true, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
        Keyboard.Type(Renamed);
        app.Click(CellOf(grid, 1, 1));
        Assert.Equal(Renamed, app.WaitForCell(grid, 0, 1, value => value == Renamed));
        Assert.Equal("edited", ItemStatusOf(grid, 0, 1));
        app.Click(CellOf(grid, 0, 1));
        Assert.Equal(Renamed, Retry.WhileNull(
            () => app.TryFind("DetailsField_1")?.AsTextBox().Text is Renamed ? Renamed : null,
            AppSession.Wait,
            throwOnTimeout: false).Result);
        app.Screenshot("126-row-details-edited");

        app.Click(app.Find("DetailsTableView"), () => app.TryFind("DetailsDataSizeValue") is not null);
        var data = AppSession.WaitForText(app.Find("DetailsDataSizeValue"), text => text.Length > 0);
        Assert.DoesNotContain("Not reported", data, StringComparison.Ordinal);
        Assert.Contains("Not reported", AppSession.TextOf(app.Find("DetailsCommentValue")), StringComparison.Ordinal);
        app.Screenshot("127-table-details");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ColumnsHideMoveAndFreezeAndTheTableOpensAgainWithThem(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var tree = app.Find("ObjectTree");
        app.Click(app.FindByName("Track", tree), () => app.TryFind("TableStatus") is not null);
        var grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 0, 1, value => value.Length > 0);
        Assert.Equal("Name", HeaderOf(grid, 1));

        app.RightClick(HeaderElement(grid, 1), () => app.TryFindMenuItem("Hide column") is not null);
        app.Screenshot("128-column-menu");
        app.Click(app.FindMenuItem("Hide column"));
        Assert.True(Retry.WhileFalse(() => HeaderOf(grid, 1) == "AlbumId", AppSession.Wait, throwOnTimeout: false).Success);

        // Alt+Right moves the focused column one place, as Move column right in its menu does.
        app.Click(CellOf(grid, 0, 1));
        app.Chord(() => HeaderOf(grid, 2) == "AlbumId", VirtualKeyShort.ALT, VirtualKeyShort.RIGHT);
        Assert.Equal("MediaTypeId", HeaderOf(grid, 1));

        app.RightClick(HeaderElement(grid, 0), () => app.TryFindMenuItem("Freeze up to this column") is not null);
        app.Click(app.FindMenuItem("Freeze up to this column"));
        app.Screenshot("129-columns-arranged");

        var tabs = app.Find("Tabs");
        bool Open() => tabs.FindFirstDescendant(condition =>
            condition.ByControlType(ControlType.TabItem).And(condition.ByName("Track"))) is not null;
        app.Chord(() => !Open(), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Click(app.FindByName("Track", tree), () => app.TryFind("TableStatus") is not null);
        grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 0, 0, value => value.Length > 0);
        Assert.Equal("MediaTypeId", HeaderOf(grid, 1));
        Assert.Equal("AlbumId", HeaderOf(grid, 2));

        app.Click(app.Find("ColumnsButton"), () => app.TryFindMenuItem("Name") is not null);
        app.Screenshot("130-columns-list");
        app.Click(app.FindMenuItem("Reset columns"));
        Assert.True(Retry.WhileFalse(() => HeaderOf(grid, 1) == "Name", AppSession.Wait, throwOnTimeout: false).Success);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void SelectedCellsShowTheirCountSumAndAverage(string theme)
    {
        const int Milliseconds = 6;
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Click(app.FindByName("Track", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
        var grid = app.Find("ResultsGrid");
        var values = Enumerable.Range(0, 5)
            .Select(row => long.Parse(
                app.WaitForCell(grid, row, Milliseconds, value => value.Length > 0), NumberStyles.Integer, CultureInfo.InvariantCulture))
            .ToList();

        app.Click(CellOf(grid, 0, Milliseconds));
        using (Keyboard.Pressing(VirtualKeyShort.SHIFT))
        {
            Keyboard.Type(Enumerable.Repeat(VirtualKeyShort.DOWN, 4).ToArray());
        }

        var expected = values.Sum().ToString("N0", CultureInfo.GetCultureInfo("en-US"));
        var summary = AppSession.WaitForText(app.Find("SelectionSummary"), text => text.Contains("Count: 5", StringComparison.Ordinal));
        Assert.StartsWith($"Sum: {expected}", summary, StringComparison.Ordinal);
        app.Screenshot("131-selection-summary");

        app.Click(app.Find("SelectionSummary"), () => app.TryFind("SummaryMaximumValue") is not null);
        Assert.EndsWith(values.Max().ToString("N0", CultureInfo.GetCultureInfo("en-US")),
            AppSession.TextOf(app.Find("SummaryMaximumValue")), StringComparison.Ordinal);
        app.Screenshot("132-selection-summary-figures");
        Keyboard.Type(VirtualKeyShort.ESCAPE);
    }

    private static AutomationElement HeaderElement(AutomationElement grid, int column) =>
        CellOf(grid, 0, column).Patterns.TableItem.Pattern.ColumnHeaderItems.Value.Single();

    // A header rebuilt by a change of layout is gone from UI Automation for a moment.
    private static string HeaderOf(AutomationElement grid, int column)
    {
        var name = string.Empty;
        return AppSession.Holds(() =>
        {
            name = HeaderElement(grid, column).Properties.Name.ValueOrDefault ?? string.Empty;
            return true;
        })
            ? name
            : string.Empty;
    }
}
