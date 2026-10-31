using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using TablePro.Core.Localization;

namespace TablePro.Core.Updates;

/// <summary>What a release asset is, which decides how the app installs it.</summary>
public enum UpdateAssetKind
{
    /// <summary>The self-contained build with the per-user install script.</summary>
    Zip,

    /// <summary>The MSIX package for one architecture, which App Installer opens.</summary>
    Msix,
}

/// <summary>One downloadable file of a release, with the digest the download must match.</summary>
public sealed record UpdateAsset(UpdateAssetKind Kind, Architecture Architecture, Uri Url, long Size, string Sha256);

/// <summary>One release in the feed: the Windows counterpart of an appcast item.</summary>
public sealed record UpdateItem
{
    public required AppVersion Version { get; init; }

    public UpdateChannel Channel => Version.Channel;

    public required DateTimeOffset Published { get; init; }

    /// <summary>A security or data-loss fix, as <c>[CRITICAL]</c> marks one on macOS. It skips phasing and skipping.</summary>
    public bool Critical { get; init; }

    /// <summary>The gap between rollout groups, as Sparkle's <c>phasedRolloutInterval</c>; null releases to all at once.</summary>
    public TimeSpan? PhasedRolloutInterval { get; init; }

    /// <summary>The lowest Windows build the release runs on, 0 for no limit.</summary>
    public int MinimumWindowsBuild { get; init; }

    public Uri? ReleaseNotesUrl { get; init; }

    /// <summary>Release notes in Markdown, shown before the user installs.</summary>
    public string? Notes { get; init; }

    public IReadOnlyList<UpdateAsset> Assets { get; init; } = [];

    public UpdateAsset? FindAsset(UpdateAssetKind kind, Architecture architecture) =>
        Assets.FirstOrDefault(a => a.Kind == kind && a.Architecture == architecture);
}

/// <summary>
/// The Windows update feed, <c>https://updates.tablepro.app/windows/feed.json</c>. The release workflow writes it
/// (<c>windows/packaging/Update-Feed.ps1</c>); the app reads it with <see cref="Parse(string)"/>.
/// </summary>
public sealed class UpdateFeed
{
    /// <summary>The format this build reads. A field added later keeps the number; a change old apps misread raises it.</summary>
    public const int SchemaVersion = 1;

    private UpdateFeed(IReadOnlyList<UpdateItem> items) => Items = items;

    /// <summary>Every release the feed lists that this build understands, newest first.</summary>
    public IReadOnlyList<UpdateItem> Items { get; }

    /// <summary>
    /// Reads a feed. An item or asset this build cannot use, such as an unknown kind or a URL that is not HTTPS, is
    /// left out rather than failing the feed, so a later release can add to it without breaking older apps.
    /// </summary>
    /// <exception cref="FormatException">The text is not a feed, or its schema is newer than this build reads.</exception>
    public static UpdateFeed Parse(string json)
    {
        FeedDocumentDto? document;
        try
        {
            document = JsonSerializer.Deserialize(json, UpdateJsonContext.Default.FeedDocumentDto);
        }
        catch (JsonException ex)
        {
            throw new FormatException(CoreStrings.Get("Updates/FeedNotJson"), ex);
        }

        if (document is null)
        {
            throw new FormatException(CoreStrings.Get("Updates/FeedEmpty"));
        }

        if (document.Schema != SchemaVersion)
        {
            throw new FormatException(CoreStrings.Format("Updates/FeedSchema",
                document.Schema.ToString(CultureInfo.InvariantCulture), SchemaVersion.ToString(CultureInfo.InvariantCulture)));
        }

        var items = (document.Items ?? [])
            .Select(ToItem)
            .OfType<UpdateItem>()
            .OrderByDescending(i => i.Version)
            .ToArray();
        return new UpdateFeed(items);
    }

    private static UpdateItem? ToItem(FeedItemDto? dto)
    {
        if (dto is null || !AppVersion.TryParse(dto.Version, out var version) || dto.Published is not { } published)
        {
            return null;
        }

        return new UpdateItem
        {
            Version = version,
            Published = published,
            Critical = dto.Critical,
            PhasedRolloutInterval = dto.PhasedRolloutInterval is > 0 and var seconds ? TimeSpan.FromSeconds(seconds) : null,
            MinimumWindowsBuild = Math.Max(0, dto.MinimumWindowsBuild),
            ReleaseNotesUrl = HttpsUri(dto.ReleaseNotesUrl),
            Notes = string.IsNullOrWhiteSpace(dto.Notes) ? null : dto.Notes,
            Assets = (dto.Assets ?? []).Select(ToAsset).OfType<UpdateAsset>().ToArray(),
        };
    }

    private static UpdateAsset? ToAsset(FeedAssetDto? dto)
    {
        if (dto is null || HttpsUri(dto.Url) is not { } url || dto.Size <= 0 || !IsSha256(dto.Sha256))
        {
            return null;
        }

        UpdateAssetKind? kind = dto.Kind switch
        {
            "zip" => UpdateAssetKind.Zip,
            "msix" => UpdateAssetKind.Msix,
            _ => null,
        };
        Architecture? architecture = dto.Architecture switch
        {
            "x64" => Architecture.X64,
            "arm64" => Architecture.Arm64,
            _ => null,
        };
        return kind is { } k && architecture is { } a
            ? new UpdateAsset(k, a, url, dto.Size, dto.Sha256!.ToLowerInvariant())
            : null;
    }

    // The feed travels over HTTPS, and so must everything it points at, or a network attacker could swap the download
    // and the digest together.
    private static Uri? HttpsUri(string? text) =>
        Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps ? uri : null;

    private static bool IsSha256(string? text) => text is { Length: 64 } && text.All(char.IsAsciiHexDigit);
}

internal sealed class FeedDocumentDto
{
    public int Schema { get; set; }

    public List<FeedItemDto?>? Items { get; set; }
}

internal sealed class FeedItemDto
{
    public string? Version { get; set; }

    public DateTimeOffset? Published { get; set; }

    public bool Critical { get; set; }

    public int? PhasedRolloutInterval { get; set; }

    public int MinimumWindowsBuild { get; set; }

    public string? ReleaseNotesUrl { get; set; }

    public string? Notes { get; set; }

    public List<FeedAssetDto?>? Assets { get; set; }
}

internal sealed class FeedAssetDto
{
    public string? Kind { get; set; }

    public string? Architecture { get; set; }

    public string? Url { get; set; }

    public long Size { get; set; }

    public string? Sha256 { get; set; }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    WriteIndented = true,
    UseStringEnumConverter = true)]
[JsonSerializable(typeof(FeedDocumentDto))]
[JsonSerializable(typeof(UpdatePreferences))]
internal sealed partial class UpdateJsonContext : JsonSerializerContext;
