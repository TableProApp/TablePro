using System.Runtime.InteropServices;
using TablePro.Core.Updates;

namespace TablePro.Core.Tests.Updates;

public sealed class UpdateFeedTests
{
    [Fact]
    public void ReadsItemsNewestFirstAndDropsWhatItCannotUse()
    {
        var feed = UpdateFeed.Parse(FeedFixtures.Sample);

        // The -rc item has a version macOS refuses too, and the bare 0.1.0 has no publish date.
        Assert.Equal(["0.2.0-beta.1", "0.1.1"], feed.Items.Select(i => i.Version.ToString()));
    }

    [Fact]
    public void ReadsEveryFieldOfAnItem()
    {
        var stable = UpdateFeed.Parse(FeedFixtures.Sample).Items[1];

        Assert.Equal(UpdateChannel.Stable, stable.Channel);
        Assert.Equal(new DateTimeOffset(2026, 10, 30, 8, 0, 0, TimeSpan.Zero), stable.Published);
        Assert.Equal(TimeSpan.FromHours(6), stable.PhasedRolloutInterval);
        Assert.Equal(19041, stable.MinimumWindowsBuild);
        Assert.Equal("Stable notes", stable.Notes);
        Assert.False(stable.Critical);
        Assert.Null(stable.ReleaseNotesUrl);
    }

    [Fact]
    public void KeepsOnlyHttpsAssetsOfKnownKindsWithAFullDigest()
    {
        var stable = UpdateFeed.Parse(FeedFixtures.Sample).Items[1];

        Assert.Equal(2, stable.Assets.Count);
        var zip = stable.FindAsset(UpdateAssetKind.Zip, Architecture.X64);
        Assert.NotNull(zip);
        Assert.Equal(1234, zip.Size);
        Assert.Equal(FeedFixtures.ZipX64Sha, zip.Sha256);
        var msix = stable.FindAsset(UpdateAssetKind.Msix, Architecture.Arm64);
        Assert.NotNull(msix);
        Assert.Equal(FeedFixtures.MsixArm64Sha.ToLowerInvariant(), msix.Sha256);
        Assert.Null(stable.FindAsset(UpdateAssetKind.Zip, Architecture.Arm64));
        Assert.Null(stable.FindAsset(UpdateAssetKind.Msix, Architecture.X64));
    }

    [Fact]
    public void ABetaHasTheBetaChannelAndNoPhasing()
    {
        var beta = UpdateFeed.Parse(FeedFixtures.Sample).Items[0];

        Assert.Equal(UpdateChannel.Beta, beta.Channel);
        Assert.Null(beta.PhasedRolloutInterval);
        Assert.Equal(new Uri("https://github.com/TableProApp/TablePro/releases/tag/windows-v0.2.0-beta.1"), beta.ReleaseNotesUrl);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("null")]
    [InlineData("""{ "schema": 2, "items": [] }""")]
    [InlineData("""{ "items": [] }""")]
    public void RefusesWhatIsNotAFeedThisBuildReads(string json)
    {
        Assert.Throws<FormatException>(() => UpdateFeed.Parse(json));
    }

    [Fact]
    public void AFeedWithNoItemsIsEmpty()
    {
        Assert.Empty(UpdateFeed.Parse("""{ "schema": 1 }""").Items);
    }
}
