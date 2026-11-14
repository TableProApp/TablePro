using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    private const string Endless =
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c";

    [Theory]
    [MemberData(nameof(Themes))]
    public void EmptyingATableAsksFirstAndCancelRunsNothing(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "DELETE FROM Track");
        app.Chord(() => app.TryFind("ConfirmRunStatements") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);

        Assert.Contains("DELETE FROM Track", app.Find("ConfirmRunStatements").Name, StringComparison.Ordinal);
        app.Screenshot("39-run-asked");
        app.CloseDialog();
        app.TypeInto("Query 1", "SELECT COUNT(*) = 3503 FROM Track;");
        app.Chord(() => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Assert.Equal("1", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "1"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ReconnectAsksBeforeRollingBackAndBringsTheTabsBack(string theme)
    {
        const string Update = "BEGIN; UPDATE Track SET Name = 'Pending' WHERE TrackId = 1;";
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", Update);
        app.Chord(() => app.TryFind("CommitButton") is { IsOffscreen: false }, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);

        ReconnectUntilAsked(app);
        app.CloseDialog();
        Assert.True(app.Find("CommitButton").IsEnabled);

        ReconnectUntilAsked(app);
        app.Screenshot("40-reconnect-asked");
        app.PressDialogButton();
        var rolledBack = Retry.WhileFalse(
            () => app.TryFind("CommitButton") is null or { IsOffscreen: true },
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(rolledBack);
        Assert.Equal(Update, AppSession.EditorText(app.FindEditor("Query 1")).TrimEnd('\r', '\n'));
        app.TypeInto("Query 1", "SELECT COUNT(*) FROM Track WHERE TrackId = 1 AND Name = 'Pending';");
        app.Chord(() => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Assert.Equal("0", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "0"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ClosingATabWhileItsQueryRunsLeavesTheAppRunning(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        var tabs = app.Find("Tabs");
        bool Open() => tabs.FindFirstDescendant(condition => condition.ByName("Query 2")) is not null;
        app.Chord(Open, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.TypeInto("Query 2", Endless);
        app.Chord(() => app.Find("StopButton").IsEnabled, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        app.Chord(() => !Open(), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);

        AnswerRuns(app);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ReconnectingWhileAQueryRunsBringsItsTabBack(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", Endless);
        app.Chord(() => app.Find("StopButton").IsEnabled, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Reconnect(app);

        var back = Retry.WhileFalse(
            () => AppSession.EditorText(app.FindEditor("Query 1")).TrimEnd('\r', '\n') == Endless,
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(back);
        AnswerRuns(app);
    }

    // The app outlived the close, and its connection still runs a query.
    private static void AnswerRuns(AppSession app)
    {
        app.TypeInto("Query 1", "SELECT 42 AS answer;");
        app.Chord(() => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Assert.Equal("42", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "42"));
    }

    private static void Reconnect(AppSession app)
    {
        app.Click(app.Find("DatabaseMenu"), () => app.TryFindMenuItem("Reconnect") is not null);
        app.FindMenuItem("Reconnect").Patterns.Invoke.Pattern.Invoke();
    }

    // The prompt opens after the menu item returns, and until then CloseButton finds the tab's own close button.
    private static void ReconnectUntilAsked(AppSession app)
    {
        Reconnect(app);
        var asked = Retry.WhileFalse(
            () => app.TryFind("PrimaryButton") is not null,
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(asked, "Reconnect did not ask about the open transaction.");
    }
}
