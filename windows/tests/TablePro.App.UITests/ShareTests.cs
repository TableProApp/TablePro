using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// The sheet as a runner can show it: signed out, since no test signs in to tablepro.app.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void AResultAndAQueryOpenTheShareSheetWhichAsksToSignIn(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "SELECT TrackId, Name FROM Track");
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: ", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        Assert.Equal("1", app.WaitForCell(grid, 0, 0, value => value == "1"));

        // The results grid's own menu, which a query tab had none of.
        app.RightClick(CellOf(grid, 0, 1), () => app.TryFindMenuItem("Share result...") is not null);
        app.Click(app.FindMenuItem("Share result..."), () => app.TryFind("ShareSignInButton") is not null);
        Assert.Equal("Sign in...", app.Find("ShareSignInButton").Name);
        app.Screenshot("61-share-result-signed-out");
        app.CloseDialog();
        Assert.True(Retry.WhileTrue(() => app.TryFind("ShareSignInButton") is not null, AppSession.Wait, throwOnTimeout: false).Success);

        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Share query...") is not null);
        app.Click(app.FindMenuItem("Share query..."), () => app.TryFind("ShareSignInButton") is not null);
        app.Screenshot("62-share-query-signed-out");
        app.CloseDialog();
        Assert.True(Retry.WhileTrue(() => app.TryFind("ShareSignInButton") is not null, AppSession.Wait, throwOnTimeout: false).Success);
    }
}
