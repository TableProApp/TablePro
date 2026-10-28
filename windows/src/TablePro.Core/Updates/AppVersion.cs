using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text.RegularExpressions;

namespace TablePro.Core.Updates;

/// <summary>
/// A release version: <c>X.Y.Z</c> for a stable and <c>X.Y.Z-beta.N</c> for a beta, the same scheme the macOS app
/// tags with. Every part fits an MSIX version field, so <see cref="PackageVersion"/> always exists.
/// </summary>
public readonly partial record struct AppVersion : IComparable<AppVersion>
{
    /// <summary>The revision a stable takes in its package version, above every beta of the same release.</summary>
    public const int StableRevision = 99;

    /// <summary>The highest beta number, so a beta's revision stays below <see cref="StableRevision"/>.</summary>
    public const int MaxBeta = 98;

    public AppVersion(int major, int minor, int patch, int beta = 0)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(major);
        ArgumentOutOfRangeException.ThrowIfNegative(minor);
        ArgumentOutOfRangeException.ThrowIfNegative(patch);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(major, ushort.MaxValue);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(minor, ushort.MaxValue);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(patch, ushort.MaxValue);
        ArgumentOutOfRangeException.ThrowIfNegative(beta);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(beta, MaxBeta);
        Major = major;
        Minor = minor;
        Patch = patch;
        Beta = beta;
    }

    public int Major { get; }

    public int Minor { get; }

    public int Patch { get; }

    /// <summary>The beta number, or 0 for a stable.</summary>
    public int Beta { get; }

    public bool IsBeta => Beta > 0;

    /// <summary>The channel a release of this version ships on.</summary>
    public UpdateChannel Channel => IsBeta ? UpdateChannel.Beta : UpdateChannel.Stable;

    /// <summary>
    /// The four-part MSIX version. Windows orders packages by it, so a beta's revision is its number and a stable's
    /// is 99: 0.2.0-beta.1 is 0.2.0.1 and 0.2.0 is 0.2.0.99, and App Installer upgrades from one to the next.
    /// </summary>
    public Version PackageVersion => new(Major, Minor, Patch, IsBeta ? Beta : StableRevision);

    public static bool operator <(AppVersion left, AppVersion right) => left.CompareTo(right) < 0;

    public static bool operator >(AppVersion left, AppVersion right) => left.CompareTo(right) > 0;

    public static bool operator <=(AppVersion left, AppVersion right) => left.CompareTo(right) <= 0;

    public static bool operator >=(AppVersion left, AppVersion right) => left.CompareTo(right) >= 0;

    /// <summary>
    /// Reads a version, a tag (<c>windows-v0.2.0</c>, <c>v0.2.0</c>) or an informational version with build
    /// metadata (<c>0.2.0-beta.1+3f2a9c1</c>). A prerelease other than <c>beta.N</c> is refused, as macOS refuses it.
    /// </summary>
    public static bool TryParse([NotNullWhen(true)] string? text, out AppVersion version)
    {
        version = default;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var match = VersionPattern().Match(text.Trim());
        if (!match.Success
            || !TryPart(match.Groups["major"].Value, out var major)
            || !TryPart(match.Groups["minor"].Value, out var minor)
            || !TryPart(match.Groups["patch"].Value, out var patch))
        {
            return false;
        }

        var beta = 0;
        if (match.Groups["beta"].Success
            && (!int.TryParse(match.Groups["beta"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out beta) || beta is < 1 or > MaxBeta))
        {
            return false;
        }

        version = new AppVersion(major, minor, patch, beta);
        return true;
    }

    public static AppVersion Parse(string text) =>
        TryParse(text, out var version) ? version : throw new FormatException($"'{text}' is not a TablePro version such as 0.2.0 or 0.2.0-beta.1.");

    public int CompareTo(AppVersion other)
    {
        var order = Major.CompareTo(other.Major);
        if (order == 0)
        {
            order = Minor.CompareTo(other.Minor);
        }

        if (order == 0)
        {
            order = Patch.CompareTo(other.Patch);
        }

        // A stable outranks every beta of the same release, which is what the revision encodes too.
        return order != 0 ? order : Revision(this).CompareTo(Revision(other));
    }

    public override string ToString() => IsBeta
        ? string.Create(CultureInfo.InvariantCulture, $"{Major}.{Minor}.{Patch}-beta.{Beta}")
        : string.Create(CultureInfo.InvariantCulture, $"{Major}.{Minor}.{Patch}");

    private static int Revision(AppVersion version) => version.IsBeta ? version.Beta : StableRevision;

    private static bool TryPart(string text, out int value) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value) && value <= ushort.MaxValue;

    [GeneratedRegex(@"^(?:windows-)?v?(?<major>\d{1,5})\.(?<minor>\d{1,5})\.(?<patch>\d{1,5})(?:-beta\.(?<beta>\d{1,2}))?(?:\+[0-9A-Za-z.-]+)?$", RegexOptions.CultureInvariant)]
    private static partial Regex VersionPattern();
}
