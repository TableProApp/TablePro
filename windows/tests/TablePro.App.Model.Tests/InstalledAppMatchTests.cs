namespace TablePro.App.Model.Tests;

// How the setup guide finds another app's Uninstall entry and the icon file it names.
public sealed class InstalledAppMatchTests
{
    [Theory]
    [InlineData("Source App", true)]
    [InlineData("source app", true)]
    [InlineData("  Source App  ", true)]
    [InlineData("Source App 24.1.0", true)]
    [InlineData("SOURCE APP Community Edition", true)]
    [InlineData("Source Apparatus", false)]
    [InlineData("Source", false)]
    [InlineData("My Source App", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void AnEntryMatchesTheAppAloneOrFollowedByAVersionOrEdition(string? displayName, bool expected) =>
        Assert.Equal(expected, InstalledAppMatch.Matches(displayName, "Source App"));

    [Fact]
    public void AnEmptyAppNameMatchesNothing() =>
        Assert.False(InstalledAppMatch.Matches("Source App", " "));

    [Theory]
    [InlineData(@"C:\Program Files\Source App\app.exe", @"C:\Program Files\Source App\app.exe")]
    [InlineData(@"C:\Program Files\Source App\app.exe,0", @"C:\Program Files\Source App\app.exe")]
    [InlineData(@"C:\Program Files\Source App\app.exe, -101", @"C:\Program Files\Source App\app.exe")]
    [InlineData(@"""C:\Program Files\Source App\app.exe"",0", @"C:\Program Files\Source App\app.exe")]
    [InlineData(@"""C:\Program Files\Source App\app.exe""", @"C:\Program Files\Source App\app.exe")]
    [InlineData(@"  C:\Apps\Source, Inc\app.ico  ", @"C:\Apps\Source, Inc\app.ico")]
    [InlineData(@"%LOCALAPPDATA%\Programs\Source App\app.exe,0", @"%LOCALAPPDATA%\Programs\Source App\app.exe")]
    public void TheIconPathLosesItsQuotesAndIconIndex(string displayIcon, string expected) =>
        Assert.Equal(expected, InstalledAppMatch.IconPath(displayIcon));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(@""""",0")]
    public void NoPathGivesNoIcon(string? displayIcon) =>
        Assert.Null(InstalledAppMatch.IconPath(displayIcon));
}
