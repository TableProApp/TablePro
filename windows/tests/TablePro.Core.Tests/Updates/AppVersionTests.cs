using TablePro.Core.Updates;

namespace TablePro.Core.Tests.Updates;

public sealed class AppVersionTests
{
    [Theory]
    [InlineData("0.2.0", 0, 2, 0, 0)]
    [InlineData("1.10.3", 1, 10, 3, 0)]
    [InlineData("0.2.0-beta.1", 0, 2, 0, 1)]
    [InlineData("0.2.0-beta.98", 0, 2, 0, 98)]
    [InlineData("windows-v0.3.1", 0, 3, 1, 0)]
    [InlineData("windows-v0.3.0-beta.2", 0, 3, 0, 2)]
    [InlineData("v0.3.0", 0, 3, 0, 0)]
    [InlineData("0.2.0-beta.4+3f2a9c1e", 0, 2, 0, 4)]
    [InlineData(" 0.2.0 ", 0, 2, 0, 0)]
    public void ParsesVersionsTagsAndInformationalVersions(string text, int major, int minor, int patch, int beta)
    {
        Assert.True(AppVersion.TryParse(text, out var version));
        Assert.Equal(new AppVersion(major, minor, patch, beta), version);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("0.2")]
    [InlineData("0.2.0.1")]
    [InlineData("0.2.0-rc.1")]
    [InlineData("0.2.0-beta")]
    [InlineData("0.2.0-beta.0")]
    [InlineData("0.2.0-beta.99")]
    [InlineData("0.70000.0")]
    [InlineData("linux-v0.2.0")]
    [InlineData("-1.0.0")]
    public void RefusesWhatIsNotAReleaseVersion(string? text)
    {
        Assert.False(AppVersion.TryParse(text, out _));
    }

    [Fact]
    public void ParseNamesTheBadText()
    {
        var error = Assert.Throws<FormatException>(() => AppVersion.Parse("0.2.0-rc.1"));
        Assert.Contains("0.2.0-rc.1", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("0.2.0", "0.1.9")]
    [InlineData("0.2.0", "0.2.0-beta.5")]
    [InlineData("0.2.0-beta.2", "0.2.0-beta.1")]
    [InlineData("0.2.1-beta.1", "0.2.0")]
    [InlineData("0.10.0", "0.9.0")]
    [InlineData("1.0.0", "0.99.99")]
    public void OrdersByReleaseThenBeta(string higher, string lower)
    {
        Assert.True(AppVersion.Parse(higher) > AppVersion.Parse(lower));
        Assert.True(AppVersion.Parse(lower) < AppVersion.Parse(higher));
        Assert.True(AppVersion.Parse(higher).PackageVersion > AppVersion.Parse(lower).PackageVersion);
    }

    [Fact]
    public void BuildMetadataDoesNotChangeTheVersion()
    {
        Assert.Equal(AppVersion.Parse("0.2.0"), AppVersion.Parse("0.2.0+abc"));
        Assert.Equal(0, AppVersion.Parse("0.2.0+abc").CompareTo(AppVersion.Parse("0.2.0+def")));
    }

    [Theory]
    [InlineData("0.2.0-beta.1", "0.2.0.1")]
    [InlineData("0.2.0-beta.98", "0.2.0.98")]
    [InlineData("0.2.0", "0.2.0.99")]
    [InlineData("1.4.12", "1.4.12.99")]
    public void PackageVersionPutsTheBetaInTheRevision(string text, string package)
    {
        Assert.Equal(Version.Parse(package), AppVersion.Parse(text).PackageVersion);
    }

    [Theory]
    [InlineData("0.2.0", UpdateChannel.Stable)]
    [InlineData("0.2.0-beta.3", UpdateChannel.Beta)]
    public void TheChannelFollowsTheVersion(string text, UpdateChannel channel)
    {
        Assert.Equal(channel, AppVersion.Parse(text).Channel);
    }

    [Theory]
    [InlineData("windows-v0.2.0", "0.2.0")]
    [InlineData("0.2.0-beta.7+sha", "0.2.0-beta.7")]
    public void FormatsWithoutPrefixOrMetadata(string text, string expected)
    {
        Assert.Equal(expected, AppVersion.Parse(text).ToString());
    }

    [Fact]
    public void TheConstructorKeepsBetaWithinTheRevisionRange()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new AppVersion(0, 1, 0, 99));
        Assert.Throws<ArgumentOutOfRangeException>(() => new AppVersion(0, 70_000, 0));
    }
}
