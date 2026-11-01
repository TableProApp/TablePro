using System.Runtime.InteropServices;
using TablePro.Core.Updates;

namespace TablePro.Core.Tests.Updates;

public sealed class UpdateSelectorTests
{
    private static readonly DateTimeOffset Published = new(2026, 11, 2, 8, 0, 0, TimeSpan.Zero);

    [Fact]
    public void OffersTheNewestStableOnTheStableChannel()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0-beta.1"), Item("0.2.1"));

        var offer = UpdateSelector.Select(feed, Criteria("0.1.0"));

        Assert.NotNull(offer);
        Assert.Equal(AppVersion.Parse("0.2.1"), offer.Version);
        Assert.Equal(UpdateAssetKind.Zip, offer.Asset.Kind);
        Assert.False(offer.IsCritical);
    }

    [Fact]
    public void TheBetaChannelTakesBetasAndTheStablesAfterThem()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0-beta.1"));
        Assert.Equal(AppVersion.Parse("0.3.0-beta.1"), UpdateSelector.Select(feed, Criteria("0.2.0", UpdateChannel.Beta))!.Version);

        var promoted = Feed(Item("0.3.0-beta.2"), Item("0.3.0"));
        Assert.Equal(AppVersion.Parse("0.3.0"), UpdateSelector.Select(promoted, Criteria("0.3.0-beta.2", UpdateChannel.Beta))!.Version);
    }

    [Fact]
    public void ABetaUserBackOnStableWaitsForTheNextStable()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0-beta.1"));

        Assert.Null(UpdateSelector.Select(feed, Criteria("0.3.0-beta.1")));
    }

    [Fact]
    public void NothingIsOfferedWhenTheAppIsCurrentOrNewer()
    {
        var feed = Feed(Item("0.2.0"));

        Assert.Null(UpdateSelector.Select(feed, Criteria("0.2.0")));
        Assert.Null(UpdateSelector.Select(feed, Criteria("0.3.0")));
    }

    [Fact]
    public void SkipsAReleaseWithoutAnAssetThisInstallationCanApply()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0", kind: UpdateAssetKind.Msix), Item("0.4.0", architecture: Architecture.Arm64));

        Assert.Equal(AppVersion.Parse("0.2.0"), UpdateSelector.Select(feed, Criteria("0.1.0"))!.Version);
        Assert.Equal(AppVersion.Parse("0.3.0"), UpdateSelector.Select(feed, Criteria("0.1.0") with { AssetKind = UpdateAssetKind.Msix })!.Version);
        Assert.Equal(AppVersion.Parse("0.4.0"), UpdateSelector.Select(feed, Criteria("0.1.0") with { Architecture = Architecture.Arm64 })!.Version);
    }

    [Fact]
    public void SkipsAReleaseThatNeedsANewerWindows()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0") with { MinimumWindowsBuild = 22000 });

        Assert.Equal(AppVersion.Parse("0.2.0"), UpdateSelector.Select(feed, Criteria("0.1.0") with { WindowsBuild = 19045 })!.Version);
        Assert.Equal(AppVersion.Parse("0.3.0"), UpdateSelector.Select(feed, Criteria("0.1.0") with { WindowsBuild = 22631 })!.Version);
    }

    [Fact]
    public void APhasedReleaseReachesEachGroupOneIntervalAfterThePrevious()
    {
        var phased = Item("0.2.0") with { PhasedRolloutInterval = TimeSpan.FromHours(6) };

        Assert.True(UpdateSelector.IsRolledOutTo(phased, 0, Published));
        Assert.False(UpdateSelector.IsRolledOutTo(phased, 1, Published.AddHours(5)));
        Assert.True(UpdateSelector.IsRolledOutTo(phased, 1, Published.AddHours(6)));
        Assert.False(UpdateSelector.IsRolledOutTo(phased, 6, Published.AddHours(35)));
        Assert.True(UpdateSelector.IsRolledOutTo(phased, 6, Published.AddHours(36)));
        Assert.True(UpdateSelector.IsRolledOutTo(Item("0.2.0"), 6, Published));
    }

    [Fact]
    public void AScheduledCheckFallsBackToAnOlderReleaseWhileTheNewestPhasesIn()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0") with { PhasedRolloutInterval = TimeSpan.FromHours(6) });
        var scheduled = Criteria("0.1.0") with { RolloutGroup = 3, Now = Published.AddHours(1) };

        Assert.Equal(AppVersion.Parse("0.2.0"), UpdateSelector.Select(feed, scheduled)!.Version);
        Assert.Equal(AppVersion.Parse("0.3.0"), UpdateSelector.Select(feed, scheduled with { UserInitiated = true })!.Version);
        Assert.Equal(AppVersion.Parse("0.3.0"), UpdateSelector.Select(feed, scheduled with { Now = Published.AddHours(18) })!.Version);
    }

    [Fact]
    public void ACriticalReleaseSkipsPhasingAndStaysCriticalOnceReplaced()
    {
        var feed = Feed(
            Item("0.2.0") with { Critical = true },
            Item("0.3.0") with { PhasedRolloutInterval = TimeSpan.FromHours(6) });

        var fromOld = UpdateSelector.Select(feed, Criteria("0.1.0") with { RolloutGroup = 6, Now = Published });
        Assert.NotNull(fromOld);
        Assert.Equal(AppVersion.Parse("0.3.0"), fromOld.Version);
        Assert.True(fromOld.IsCritical);

        var pastIt = UpdateSelector.Select(feed, Criteria("0.2.0") with { RolloutGroup = 6, Now = Published });
        Assert.Null(pastIt);
    }

    [Fact]
    public void ASkippedVersionIsQuietUntilTheUserAsksOrANewerOneShips()
    {
        var feed = Feed(Item("0.2.0"));
        var skipped = Criteria("0.1.0") with { SkippedVersion = AppVersion.Parse("0.2.0") };

        Assert.Null(UpdateSelector.Select(feed, skipped));
        Assert.NotNull(UpdateSelector.Select(feed, skipped with { UserInitiated = true }));
        Assert.Equal(AppVersion.Parse("0.2.1"), UpdateSelector.Select(Feed(Item("0.2.0"), Item("0.2.1")), skipped)!.Version);
    }

    [Fact]
    public void ACriticalReleaseIsOfferedEvenWhenSkipped()
    {
        var feed = Feed(Item("0.2.0") with { Critical = true });

        var offer = UpdateSelector.Select(feed, Criteria("0.1.0") with { SkippedVersion = AppVersion.Parse("0.2.0") });

        Assert.NotNull(offer);
        Assert.True(offer.IsCritical);
    }

    [Fact]
    public void AStableUserIgnoresACriticalBeta()
    {
        var feed = Feed(Item("0.2.0"), Item("0.3.0-beta.1") with { Critical = true });

        var offer = UpdateSelector.Select(feed, Criteria("0.1.0"));

        Assert.NotNull(offer);
        Assert.False(offer.IsCritical);
    }

    private static UpdateCriteria Criteria(string current, UpdateChannel channel = UpdateChannel.Stable) => new()
    {
        CurrentVersion = AppVersion.Parse(current),
        Channel = channel,
        Architecture = Architecture.X64,
        AssetKind = UpdateAssetKind.Zip,
        WindowsBuild = 26100,
        Now = Published.AddDays(10),
    };

    private static UpdateItem Item(string version, UpdateAssetKind kind = UpdateAssetKind.Zip, Architecture architecture = Architecture.X64) => new()
    {
        Version = AppVersion.Parse(version),
        Published = Published,
        MinimumWindowsBuild = 19041,
        Assets = [new UpdateAsset(kind, architecture, new Uri($"https://example.test/{version}"), 10, new string('0', 64))],
    };

    private static UpdateFeed Feed(params UpdateItem[] items)
    {
        // The feed type is built only by parsing, as the app builds it, so the items go through JSON.
        var json = System.Text.Json.JsonSerializer.Serialize(new
        {
            schema = 1,
            items = items.Select(i => new
            {
                version = i.Version.ToString(),
                published = i.Published,
                critical = i.Critical,
                phasedRolloutInterval = i.PhasedRolloutInterval is { } p ? (int?)p.TotalSeconds : null,
                minimumWindowsBuild = i.MinimumWindowsBuild,
                assets = i.Assets.Select(a => new
                {
                    kind = a.Kind == UpdateAssetKind.Zip ? "zip" : "msix",
                    architecture = a.Architecture == Architecture.Arm64 ? "arm64" : "x64",
                    url = a.Url.ToString(),
                    size = a.Size,
                    sha256 = a.Sha256,
                }),
            }),
        });
        return UpdateFeed.Parse(json);
    }
}
