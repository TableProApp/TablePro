using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;

namespace TablePro.Core.Licensing;

/// <summary>
/// The <c>data</c> half of the license the server signs, key for key as the macOS app reads it. Every value that
/// decides gating comes from here, so a forged value has nowhere to live: the signature covers all of it.
/// </summary>
public sealed record LicensePayload
{
    [JsonPropertyName("billing_cycle")]
    public string? BillingCycle { get; init; }

    [JsonPropertyName("license_key")]
    public required string LicenseKey { get; init; }

    [JsonPropertyName("email")]
    public required string Email { get; init; }

    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("expires_at")]
    public string? ExpiresAt { get; init; }

    [JsonPropertyName("issued_at")]
    public required string IssuedAt { get; init; }

    [JsonPropertyName("tier")]
    public required string Tier { get; init; }

    /// <summary>Signed only for a Team license.</summary>
    [JsonPropertyName("team_id")]
    public string? TeamId { get; init; }

    [JsonPropertyName("role")]
    public string? Role { get; init; }

    /// <summary>The machine the server minted this payload for. A payload signed before machine binding has none.</summary>
    [JsonPropertyName("machine_id")]
    public string? MachineId { get; init; }

    /// <summary>
    /// The exact bytes the server signed. It signs <c>json_encode(ksort($data), JSON_UNESCAPED_SLASHES)</c>, so keys
    /// are in ordinal order, a slash stays raw, <c>billing_cycle</c> and <c>expires_at</c> are written as null when
    /// absent, and <c>team_id</c>, <c>role</c> and <c>machine_id</c> are left out when absent, because the server
    /// omits them unless they apply and a payload signed before they existed must still verify.
    /// </summary>
    /// <param name="escapeNonAscii">
    /// False writes other characters as UTF-8, as the macOS verifier does; true writes them as <c>\uXXXX</c>, as PHP's
    /// json_encode does without JSON_UNESCAPED_UNICODE.
    /// </param>
    public byte[] CanonicalJson(bool escapeNonAscii = false)
    {
        var json = new StringBuilder(256).Append('{');
        Member(json, "billing_cycle", BillingCycle, writeNull: true, escapeNonAscii);
        Member(json, "email", Email, writeNull: true, escapeNonAscii);
        Member(json, "expires_at", ExpiresAt, writeNull: true, escapeNonAscii);
        Member(json, "issued_at", IssuedAt, writeNull: true, escapeNonAscii);
        Member(json, "license_key", LicenseKey, writeNull: true, escapeNonAscii);
        Member(json, "machine_id", MachineId, writeNull: false, escapeNonAscii);
        Member(json, "role", Role, writeNull: false, escapeNonAscii);
        Member(json, "status", Status, writeNull: true, escapeNonAscii);
        Member(json, "team_id", TeamId, writeNull: false, escapeNonAscii);
        Member(json, "tier", Tier, writeNull: true, escapeNonAscii);
        return Encoding.UTF8.GetBytes(json.Append('}').ToString());
    }

    /// <summary>Whether any signed value holds a character the two encodings write differently.</summary>
    internal bool HasNonAscii() =>
        new[] { BillingCycle, LicenseKey, Email, Status, ExpiresAt, IssuedAt, Tier, TeamId, Role, MachineId }
            .Any(v => v is not null && !Ascii.IsValid(v));

    private static void Member(StringBuilder json, string key, string? value, bool writeNull, bool escapeNonAscii)
    {
        if (value is null && !writeNull)
        {
            return;
        }

        if (json.Length > 1)
        {
            json.Append(',');
        }

        json.Append('"').Append(key).Append("\":");
        if (value is null)
        {
            json.Append("null");
            return;
        }

        json.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"':
                    json.Append("\\\"");
                    break;
                case '\\':
                    json.Append("\\\\");
                    break;
                case '\b':
                    json.Append("\\b");
                    break;
                case '\f':
                    json.Append("\\f");
                    break;
                case '\n':
                    json.Append("\\n");
                    break;
                case '\r':
                    json.Append("\\r");
                    break;
                case '\t':
                    json.Append("\\t");
                    break;
                case < ' ':
                    json.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    break;
                case > '\x7f' when escapeNonAscii:
                    json.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    break;
                default:
                    json.Append(c);
                    break;
            }
        }

        json.Append('"');
    }
}

/// <summary>The license as the server returns it: the payload and its RSA-SHA256 signature, base64.</summary>
public sealed record SignedLicensePayload
{
    [JsonPropertyName("data")]
    public required LicensePayload Data { get; init; }

    [JsonPropertyName("signature")]
    public required string Signature { get; init; }
}
