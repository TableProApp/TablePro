namespace TablePro.Core.Licensing;

public enum LicenseTierKind
{
    Starter,
    Team,
    Unknown,
}

/// <summary>
/// The plan a license belongs to. A higher tier unlocks everything a lower one does. The server owns the vocabulary, so
/// a tier this build has never heard of keeps its raw name and ranks above every known tier: a future paid plan is
/// never wrongly restricted by an older build.
/// </summary>
public readonly record struct LicenseTier(LicenseTierKind Kind, string Raw)
{
    public static LicenseTier Starter { get; } = new(LicenseTierKind.Starter, "starter");

    public static LicenseTier Team { get; } = new(LicenseTierKind.Team, "team");

    internal int Rank => Kind switch
    {
        LicenseTierKind.Starter => 0,
        LicenseTierKind.Team => 1,
        _ => int.MaxValue,
    };

    /// <summary>A blank tier reads as Starter rather than as an unknown super-tier, which would unlock everything.</summary>
    public static LicenseTier Parse(string? raw)
    {
        var value = raw?.Trim() ?? string.Empty;
        if (value.Length == 0 || value.Equals("starter", StringComparison.OrdinalIgnoreCase))
        {
            return Starter;
        }

        return value.Equals("team", StringComparison.OrdinalIgnoreCase) ? Team : new LicenseTier(LicenseTierKind.Unknown, raw!);
    }

    /// <summary>Whether this tier unlocks a feature that requires <paramref name="required"/>.</summary>
    public bool Unlocks(LicenseTier required) => Rank >= required.Rank;

    public bool Equals(LicenseTier other) =>
        Kind == other.Kind && (Kind != LicenseTierKind.Unknown || string.Equals(Raw, other.Raw, StringComparison.Ordinal));

    public override int GetHashCode() => Kind == LicenseTierKind.Unknown ? HashCode.Combine(Kind, Raw) : Kind.GetHashCode();
}
