using System.Globalization;
using System.Xml;
using System.Xml.Linq;

namespace TablePro.App.Model;

public enum UpdateChannel
{
    Stable,
    Beta,
}

// The App Installer files release-windows.yml publishes, one per channel (docs/decisions/0020-app-installer-updates.md).
public static class UpdateFeeds
{
    public static Uri Stable { get; } = new("https://updates.tablepro.app/windows/TablePro.appinstaller");

    public static Uri Beta { get; } = new("https://updates.tablepro.app/windows/TablePro-Beta.appinstaller");

    public static Uri For(UpdateChannel channel) => channel == UpdateChannel.Beta ? Beta : Stable;

    public static UpdateChannel? ChannelOf(Uri? file) =>
        file is null ? null
        : Same(file, Stable) ? UpdateChannel.Stable
        : Same(file, Beta) ? UpdateChannel.Beta
        : null;

    // What Settings shows: the choice made there, else the channel of the file the app was installed from.
    public static UpdateChannel Effective(Uri? installedFrom, UpdateChannel? chosen) =>
        chosen ?? ChannelOf(installedFrom) ?? UpdateChannel.Stable;

    // The file Windows installed from decides, unless Settings chose the other channel: then that channel's does.
    public static Uri ToCheck(Uri? installedFrom, UpdateChannel? chosen) => installedFrom switch
    {
        null => For(Effective(null, chosen)),
        _ when chosen is { } wanted && ChannelOf(installedFrom) is { } channel && channel != wanted => For(wanted),
        _ => installedFrom,
    };

    // A channel file names a bundle on this repository's Windows releases and nowhere else.
    public static bool IsReleaseBundle(Uri bundle) =>
        bundle is { IsAbsoluteUri: true, Scheme: "https" }
        && string.Equals(bundle.Host, "github.com", StringComparison.OrdinalIgnoreCase)
        && bundle.AbsolutePath.StartsWith("/TableProApp/TablePro/releases/download/windows-v", StringComparison.Ordinal);

    internal static bool Same(Uri a, Uri b) => Uri.Compare(
        a, b, UriComponents.AbsoluteUri, UriFormat.SafeUnescaped, StringComparison.OrdinalIgnoreCase) == 0;
}

// The main bundle an App Installer file installs, where it comes from, and where the file says it lives.
public sealed record UpdateOffer(string Name, string Publisher, Version Version, Uri Bundle, Uri Location)
{
    public static UpdateOffer? Parse(string xml)
    {
        XDocument document;
        try
        {
            // The file comes from the network, and an App Installer file has no DTD.
            using var reader = XmlReader.Create(
                new StringReader(xml),
                new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
            document = XDocument.Load(reader);
        }
        catch (XmlException)
        {
            return null;
        }

        if (document.Root is not { Name.LocalName: "AppInstaller" } root)
        {
            return null;
        }

        var main = root.Elements().FirstOrDefault(element => element.Name.LocalName is "MainBundle" or "MainPackage");
        var name = (string?)main?.Attribute("Name");
        var publisher = (string?)main?.Attribute("Publisher");
        return name is { Length: > 0 }
            && publisher is { Length: > 0 }
            && ReleaseVersions.TryParse((string?)main?.Attribute("Version"), out var version)
            && Uri.TryCreate((string?)main?.Attribute("Uri"), UriKind.Absolute, out var bundle)
            && Uri.TryCreate((string?)root.Attribute("Uri"), UriKind.Absolute, out var location)
                ? new UpdateOffer(name, publisher, version, bundle, location)
                : null;
    }

    // Windows follows a file whose Uri names another and installs what that one names, unread; a channel file
    // also has to name a bundle of this repository's releases.
    public bool IsSafeToInstallFrom(Uri file) =>
        UpdateFeeds.Same(Location, file) && (UpdateFeeds.ChannelOf(file) is null || UpdateFeeds.IsReleaseBundle(Bundle));

    public bool IsFor(string name, string publisher) =>
        string.Equals(Name, name, StringComparison.Ordinal) && string.Equals(Publisher, publisher, StringComparison.Ordinal);
}

// A package version is X.Y.Z.R: R is N for X.Y.Z-beta.N and 99 for the release (windows/ci/appinstaller.py).
public static class ReleaseVersions
{
    public const int ReleaseRevision = 99;

    public static bool TryParse(string? text, out Version version)
    {
        version = new Version();
        var parts = text?.Split('.') ?? [];
        if (parts.Length != 4)
        {
            return false;
        }

        var numbers = new int[4];
        for (var index = 0; index < 4; index++)
        {
            if (!int.TryParse(parts[index], NumberStyles.None, CultureInfo.InvariantCulture, out numbers[index])
                || numbers[index] > ushort.MaxValue)
            {
                return false;
            }
        }

        version = new Version(numbers[0], numbers[1], numbers[2], numbers[3]);
        return true;
    }

    public static string Display(Version package)
    {
        ArgumentNullException.ThrowIfNull(package);
        var release = string.Create(CultureInfo.InvariantCulture, $"{package.Major}.{package.Minor}.{package.Build}");
        return package.Revision switch
        {
            ReleaseRevision => release,
            > 0 and < ReleaseRevision => string.Create(CultureInfo.InvariantCulture, $"{release}-beta.{package.Revision}"),
            _ => package.ToString(),
        };
    }
}

public enum LaunchKind
{
    First,
    Again,
    Update,
    Downgrade,
}

// As the Linux app's launch notice: an older build never writes over what a newer one recorded.
public static class LaunchHistory
{
    public static LaunchKind After(string? previous, Version current)
    {
        ArgumentNullException.ThrowIfNull(current);
        if (!ReleaseVersions.TryParse(previous, out var last))
        {
            return LaunchKind.First;
        }

        return last.CompareTo(current) switch
        {
            < 0 => LaunchKind.Update,
            0 => LaunchKind.Again,
            _ => LaunchKind.Downgrade,
        };
    }

    public static bool Records(LaunchKind kind) => kind is LaunchKind.First or LaunchKind.Update;
}
