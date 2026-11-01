using System.Globalization;
using System.Text.Json.Serialization;

namespace TablePro.Core.Licensing;

/// <summary>
/// The cached license: the server's signed payload and the machine it was cached on, under the two keys the macOS
/// cache uses. Everything that drives gating is read from the signed payload. <see cref="CachedOnMachineId"/> is the
/// one value written locally and it is not a security control, only the tripwire that drops a cache copied from
/// another PC; the binding that holds against tampering is <see cref="BoundMachineId"/>, which the server signs.
/// </summary>
public sealed record License
{
    [JsonPropertyName("signedPayload")]
    public required SignedLicensePayload SignedPayload { get; init; }

    [JsonPropertyName("machineId")]
    public required string CachedOnMachineId { get; init; }

    [JsonIgnore]
    public LicensePayload Payload => SignedPayload.Data;

    [JsonIgnore]
    public string Key => Payload.LicenseKey;

    [JsonIgnore]
    public string Email => Payload.Email;

    [JsonIgnore]
    public LicenseTier Tier => LicenseTier.Parse(Payload.Tier);

    [JsonIgnore]
    public string? BillingCycle => Payload.BillingCycle;

    [JsonIgnore]
    public string? BoundMachineId => Payload.MachineId;

    /// <summary>
    /// Signed only for a Team license, so its presence is the signed answer to whether other people share this license,
    /// which decides whether releasing a seat could affect somebody else.
    /// </summary>
    [JsonIgnore]
    public bool IsTeamLicense => Payload.TeamId is not null;

    [JsonIgnore]
    public TeamRole? TeamRole => Payload.Role is { } role ? Licensing.TeamRole.Parse(role) : null;

    /// <summary>Only a signed <c>active</c> may go on to count as active, so a status this build does not know withholds access.</summary>
    [JsonIgnore]
    public LicenseStatus SignedStatus => Payload.Status switch
    {
        "active" => LicenseStatus.Active,
        "expired" => LicenseStatus.Expired,
        "suspended" => LicenseStatus.Suspended,
        _ => LicenseStatus.ValidationFailed,
    };

    [JsonIgnore]
    public DateTimeOffset? ExpiresAt => ParseInternetDate(Payload.ExpiresAt);

    /// <summary>When the server signed this payload, which is when it last confirmed the license.</summary>
    [JsonIgnore]
    public DateTimeOffset? IssuedAt => ParseInternetDate(Payload.IssuedAt);

    public bool IsExpired(DateTimeOffset now) => ExpiresAt is { } expires && expires < now;

    /// <summary>Whole days until expiry, truncated toward zero; null for a license with no end.</summary>
    public int? DaysUntilExpiry(DateTimeOffset now) => ExpiresAt is { } expires ? (int)(expires - now).TotalDays : null;

    /// <summary>
    /// Whole days since the server last confirmed this license, or null when the payload does not say. A clock behind
    /// the server's reads as zero rather than as a license from the future.
    /// </summary>
    public int? DaysSinceLastValidation(DateTimeOffset now) =>
        IssuedAt is { } issued ? Math.Max(0, (int)Math.Floor((now - issued).TotalDays)) : null;

    private static readonly string[] InternetDateFormats =
    [
        "yyyy-MM-dd'T'HH:mm:ssK",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
    ];

    /// <summary>RFC 3339 with an offset or Z, the form the server writes; anything else is unreadable rather than guessed.</summary>
    public static DateTimeOffset? ParseInternetDate(string? value) =>
        value is not null && DateTimeOffset.TryParseExact(value, InternetDateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : null;
}
