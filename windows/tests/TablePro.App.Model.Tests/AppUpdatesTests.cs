namespace TablePro.App.Model.Tests;

public sealed class AppUpdatesTests
{
    private const string Publisher = "CN=TablePro, O=TablePro, C=VN";

    private const string Bundle =
        "https://github.com/TableProApp/TablePro/releases/download/windows-v0.3.0/TablePro_0.3.0.99_x64_arm64.msixbundle";

    private static string File(
        string version,
        string element = "MainBundle",
        string location = "https://updates.tablepro.app/windows/TablePro.appinstaller",
        string bundle = Bundle) => $"""
        <?xml version="1.0" encoding="utf-8"?>
        <AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2017/2" Version="{version}" Uri="{location}">
          <{element} Name="TablePro" Publisher="{Publisher}" Version="{version}" Uri="{bundle}" />
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

        Assert.Equal(new UpdateOffer("TablePro", Publisher, new Version(0, 3, 0, 2), new Uri(Bundle), UpdateFeeds.Stable), offer);
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
        Assert.Null(UpdateOffer.Parse(File("0.3.0.2", bundle: "not a uri")));
        Assert.Null(UpdateOffer.Parse(File("0.3.0.2", location: "")));
        Assert.Null(UpdateOffer.Parse("""<AppInstaller Version="1.0.0.0" Uri="https://example.invalid/a" />"""));
        Assert.Null(UpdateOffer.Parse("""
            <!DOCTYPE AppInstaller [<!ENTITY name "TablePro">]>
            <AppInstaller><MainBundle Name="&name;" Publisher="CN=A" Version="1.0.0.99" /></AppInstaller>
            """));
    }

    [Fact]
    public void OnlyAFileThatLivesWhereItWasReadAndNamesARelease()
    {
        Assert.True(UpdateOffer.Parse(File("0.3.0.99"))!.IsSafeToInstallFrom(UpdateFeeds.Stable));
        // Windows would install from the file the Uri names, which this check never read.
        Assert.False(UpdateOffer.Parse(File("0.3.0.99"))!.IsSafeToInstallFrom(UpdateFeeds.Beta));
        var elsewhere = File("0.3.0.99", location: "https://example.invalid/TablePro.appinstaller");
        Assert.False(UpdateOffer.Parse(elsewhere)!.IsSafeToInstallFrom(UpdateFeeds.Stable));
        foreach (var bundle in new[]
        {
            "https://example.invalid/TablePro.msixbundle",
            "http://github.com/TableProApp/TablePro/releases/download/windows-v0.3.0/a.msixbundle",
            "https://github.com/someone/TablePro/releases/download/windows-v0.3.0/a.msixbundle",
            "https://github.com/TableProApp/TablePro/releases/download/v0.88.0/a.msixbundle",
        })
        {
            Assert.False(UpdateOffer.Parse(File("0.3.0.99", bundle: bundle))!.IsSafeToInstallFrom(UpdateFeeds.Stable), bundle);
        }

        // A file of the install's own, as an organisation or a test hosts one, may name its bundle anywhere.
        const string local = "file:///C:/Users/runner/TablePro.appinstaller";
        var own = File("0.3.0.99", location: local, bundle: "file:///C:/Users/runner/TablePro.msixbundle");
        Assert.True(UpdateOffer.Parse(own)!.IsSafeToInstallFrom(new Uri(local)));
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

        Assert.Equal(UpdateFeeds.Beta, UpdateFeeds.ToCheck(UpdateFeeds.Beta, null));
        Assert.Equal(UpdateFeeds.Stable, UpdateFeeds.ToCheck(null, null));
        Assert.Equal(local, UpdateFeeds.ToCheck(local, null));
        Assert.Equal(UpdateChannel.Beta, UpdateFeeds.Effective(UpdateFeeds.Beta, null));
        Assert.Equal(UpdateChannel.Stable, UpdateFeeds.Effective(UpdateFeeds.Beta, UpdateChannel.Stable));
        Assert.Equal(UpdateChannel.Stable, UpdateFeeds.Effective(local, null));
        Assert.Equal(UpdateChannel.Beta, UpdateFeeds.Effective(null, UpdateChannel.Beta));
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
        Assert.Null(new AppSettings().UpdateChannel);
        var saved = new AppSettings { UpdateChannel = UpdateChannel.Beta, LastLaunchedVersion = "0.3.0.1" }.Normalized();
        Assert.Equal(UpdateChannel.Beta, saved.UpdateChannel);
        Assert.Equal("0.3.0.1", saved.LastLaunchedVersion);
        var odd = new AppSettings { UpdateChannel = (UpdateChannel)7, LastLaunchedVersion = "0.3" }.Normalized();
        Assert.Null(odd.UpdateChannel);
        Assert.Null(odd.LastLaunchedVersion);
    }
}
