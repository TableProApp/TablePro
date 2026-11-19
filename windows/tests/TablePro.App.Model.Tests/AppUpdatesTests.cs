namespace TablePro.App.Model.Tests;

public sealed class AppUpdatesTests
{
    private const string Publisher = "CN=TablePro, O=TablePro, C=VN";

    private static string File(string version, string element = "MainBundle") => $"""
        <?xml version="1.0" encoding="utf-8"?>
        <AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2017/2" Version="{version}" Uri="https://updates.tablepro.app/windows/TablePro.appinstaller">
          <{element} Name="TablePro" Publisher="{Publisher}" Version="{version}" Uri="https://example.invalid/TablePro.msixbundle" />
          <UpdateSettings>
            <OnLaunch HoursBetweenUpdateChecks="24" />
            <AutomaticBackgroundTask />
          </UpdateSettings>
        </AppInstaller>
        """;

    [Fact]
    public void AnAppInstallerFileGivesItsBundle()
    {
        var offer = UpdateOffer.Parse(File("0.3.0.2"));

        Assert.Equal(new UpdateOffer("TablePro", Publisher, new Version(0, 3, 0, 2)), offer);
        Assert.True(offer!.IsFor("TablePro", Publisher));
        Assert.False(offer.IsFor("TablePro", "CN=TablePro Development"));
        Assert.Equal(new Version(1, 2, 3, 99), UpdateOffer.Parse(File("1.2.3.99", "MainPackage"))!.Version);
    }

    [Fact]
    public void AFileThatIsNotAnAppInstallerFileGivesNothing()
    {
        Assert.Null(UpdateOffer.Parse("<html><body>Not found</body></html>"));
        Assert.Null(UpdateOffer.Parse("not xml"));
        Assert.Null(UpdateOffer.Parse(File("0.3.0")));
        Assert.Null(UpdateOffer.Parse(File("0.3.0.65536")));
        Assert.Null(UpdateOffer.Parse(File("0.3.0.-1")));
        Assert.Null(UpdateOffer.Parse("""<AppInstaller Version="1.0.0.0" Uri="https://example.invalid/a" />"""));
    }

    [Fact]
    public void APackageVersionReadsAsItsReleaseOrBeta()
    {
        Assert.Equal("0.2.0", ReleaseVersions.Display(new Version(0, 2, 0, 99)));
        Assert.Equal("0.3.0-beta.1", ReleaseVersions.Display(new Version(0, 3, 0, 1)));
        Assert.Equal("0.3.0-beta.98", ReleaseVersions.Display(new Version(0, 3, 0, 98)));
        Assert.Equal("0.1.0.0", ReleaseVersions.Display(new Version(0, 1, 0, 0)));
        Assert.Equal("0.1.0.100", ReleaseVersions.Display(new Version(0, 1, 0, 100)));
    }

    [Fact]
    public void AnInstallFollowsItsFileUnlessSettingsChoseTheOtherChannel()
    {
        var local = new Uri("file:///C:/Users/runner/TablePro.appinstaller");

        Assert.Equal(UpdateFeeds.Stable, UpdateFeeds.ToCheck(null, UpdateChannel.Stable));
        Assert.Equal(UpdateFeeds.Beta, UpdateFeeds.ToCheck(null, UpdateChannel.Beta));
        Assert.Equal(UpdateFeeds.Stable, UpdateFeeds.ToCheck(UpdateFeeds.Stable, UpdateChannel.Stable));
        Assert.Equal(UpdateFeeds.Beta, UpdateFeeds.ToCheck(UpdateFeeds.Stable, UpdateChannel.Beta));
        Assert.Equal(UpdateFeeds.Stable, UpdateFeeds.ToCheck(UpdateFeeds.Beta, UpdateChannel.Stable));
        Assert.Equal(local, UpdateFeeds.ToCheck(local, UpdateChannel.Beta));
        Assert.Equal(
            UpdateChannel.Beta,
            UpdateFeeds.ChannelOf(new Uri("HTTPS://UPDATES.TABLEPRO.APP/windows/TablePro-Beta.appinstaller")));
        Assert.Null(UpdateFeeds.ChannelOf(local));
    }

    [Fact]
    public void OnlyTheFirstStartOfANewerVersionIsAnUpdate()
    {
        var current = new Version(0, 3, 0, 1);

        Assert.Equal(LaunchKind.First, LaunchHistory.After(null, current));
        Assert.Equal(LaunchKind.First, LaunchHistory.After("not a version", current));
        Assert.Equal(LaunchKind.Update, LaunchHistory.After("0.2.0.99", current));
        Assert.Equal(LaunchKind.Update, LaunchHistory.After("0.2.10.99", new Version(0, 10, 0, 99)));
        Assert.Equal(LaunchKind.Again, LaunchHistory.After("0.3.0.1", current));
        Assert.Equal(LaunchKind.Downgrade, LaunchHistory.After("0.3.0.99", current));
        Assert.True(LaunchHistory.Records(LaunchKind.First));
        Assert.True(LaunchHistory.Records(LaunchKind.Update));
        Assert.False(LaunchHistory.Records(LaunchKind.Again));
        Assert.False(LaunchHistory.Records(LaunchKind.Downgrade));
    }

    [Fact]
    public void TheChannelAndLastVersionComeBackAsSavedAndOthersReadAsNone()
    {
        Assert.Equal(UpdateChannel.Stable, new AppSettings().UpdateChannel);
        var saved = new AppSettings { UpdateChannel = UpdateChannel.Beta, LastLaunchedVersion = "0.3.0.1" }.Normalized();
        Assert.Equal(UpdateChannel.Beta, saved.UpdateChannel);
        Assert.Equal("0.3.0.1", saved.LastLaunchedVersion);
        var odd = new AppSettings { UpdateChannel = (UpdateChannel)7, LastLaunchedVersion = "0.3" }.Normalized();
        Assert.Equal(UpdateChannel.Stable, odd.UpdateChannel);
        Assert.Null(odd.LastLaunchedVersion);
    }
}
