using System.Runtime.InteropServices;

namespace TablePro.Core.Updates;

/// <summary>What this installation is and wants, which decides the release it is offered.</summary>
public sealed record UpdateCriteria
{
    public required AppVersion CurrentVersion { get; init; }

    public required UpdateChannel Channel { get; init; }

    public required Architecture Architecture { get; init; }

    /// <summary>The asset this installation can apply: the zip for the script install, the MSIX for a package.</summary>
    public required UpdateAssetKind AssetKind { get; init; }

    public required int WindowsBuild { get; init; }

    public required DateTimeOffset Now { get; init; }

    /// <summary>This installation's rollout group, 0 to <see cref="UpdateSelector.RolloutGroupCount"/> - 1, kept across launches.</summary>
    public int RolloutGroup { get; init; }

    /// <summary>The user asked. As in Sparkle, that ignores phasing and a skipped version.</summary>
    public bool UserInitiated { get; init; }

    /// <summary>The version the user chose to skip, which a scheduled check stays quiet about.</summary>
    public AppVersion? SkippedVersion { get; init; }
}

/// <summary>The release to offer and the file to download for it.</summary>
public sealed record UpdateOffer(UpdateItem Item, UpdateAsset Asset, bool IsCritical)
{
    public AppVersion Version => Item.Version;
}

/// <summary>Picks the release an installation is offered, following Sparkle's rules for the macOS appcast.</summary>
public static class UpdateSelector
{
    /// <summary>Sparkle's group count: with a 6 hour interval a stable reaches everyone within 36 hours.</summary>
    public const int RolloutGroupCount = 7;

    public static UpdateOffer? Select(UpdateFeed feed, UpdateCriteria criteria)
    {
        var newer = feed.Items
            .Where(i => criteria.Channel.Accepts(i.Channel) && i.Version > criteria.CurrentVersion)
            .ToArray();
        // A critical release stays critical for everyone it would have reached, even once a later one replaces it,
        // as macOS carries [CRITICAL] forward.
        var critical = newer.Any(i => i.Critical);

        var best = newer
            .Where(i => i.MinimumWindowsBuild <= criteria.WindowsBuild)
            .Where(i => criteria.UserInitiated || critical || IsRolledOutTo(i, criteria.RolloutGroup, criteria.Now))
            .Select(i => (Item: i, Asset: i.FindAsset(criteria.AssetKind, criteria.Architecture)))
            .Where(c => c.Asset is not null)
            .OrderByDescending(c => c.Item.Version)
            .FirstOrDefault();
        if (best.Item is null)
        {
            return null;
        }

        if (!criteria.UserInitiated && !critical && criteria.SkippedVersion == best.Item.Version)
        {
            return null;
        }

        return new UpdateOffer(best.Item, best.Asset!, critical);
    }

    /// <summary>Group 0 gets a release at once, each later group one interval after the one before.</summary>
    public static bool IsRolledOutTo(UpdateItem item, int group, DateTimeOffset now)
    {
        if (item.PhasedRolloutInterval is not { } interval)
        {
            return true;
        }

        group = Math.Clamp(group, 0, RolloutGroupCount - 1);
        return now >= item.Published + (interval * group);
    }
}
