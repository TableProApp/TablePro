using System.Text;
using System.Text.Json;
using TablePro.Core.Licensing;

namespace TablePro.Core.Tests.Licensing;

public sealed class LicensePayloadTests
{
    private static string Canonical(LicensePayload payload, bool escapeNonAscii = false) => Encoding.UTF8.GetString(payload.CanonicalJson(escapeNonAscii));

    private static readonly LicensePayload SlashPayload = LicenseTestKeys.Payload(
        billingCycle: "yearly",
        email: "dev/ops@example.com",
        expiresAt: "2027-01-01T00:00:00+00:00",
        issuedAt: "2026-08-18T10:00:00+00:00",
        tier: "team",
        teamId: "01JXYZ",
        role: "owner");

    [Fact]
    public void CanonicalJsonIsTheBytesTheServerSigned()
    {
        // The real signer's output, the same string the macOS byte-contract test pins.
        const string expected = "{\"billing_cycle\":\"yearly\",\"email\":\"dev/ops@example.com\","
            + "\"expires_at\":\"2027-01-01T00:00:00+00:00\",\"issued_at\":\"2026-08-18T10:00:00+00:00\","
            + "\"license_key\":\"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\",\"role\":\"owner\",\"status\":\"active\","
            + "\"team_id\":\"01JXYZ\",\"tier\":\"team\"}";

        Assert.Equal(expected, Canonical(SlashPayload));
    }

    [Fact]
    public void ABoundPayloadWritesMachineIdInSortedPosition()
    {
        var bound = SlashPayload with { MachineId = "9f86d081884c7d659a2feaa0c55ad015" };

        Assert.Contains("\"license_key\":\"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\",\"machine_id\":\"9f86d081884c7d659a2feaa0c55ad015\",\"role\":\"owner\"", Canonical(bound), StringComparison.Ordinal);
    }

    [Fact]
    public void MissingCycleAndExpiryAreNullButMissingTeamFieldsAreLeftOut()
    {
        var json = Canonical(LicenseTestKeys.Payload());

        Assert.Contains("\"billing_cycle\":null", json, StringComparison.Ordinal);
        Assert.Contains("\"expires_at\":null", json, StringComparison.Ordinal);
        Assert.DoesNotContain("team_id", json, StringComparison.Ordinal);
        Assert.DoesNotContain("role", json, StringComparison.Ordinal);
        Assert.DoesNotContain("machine_id", json, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(json);
        Assert.Equal(7, document.RootElement.EnumerateObject().Count());
    }

    [Fact]
    public void QuotesBackslashesAndControlCharactersAreEscapedAsJsonRequires()
    {
        var json = Canonical(LicenseTestKeys.Payload(email: "a\"b\\c\n\x01"));

        Assert.Contains("\"email\":\"a\\\"b\\\\c\\n\\u0001\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void NonAsciiIsRawByDefaultAndEscapedTheWayPhpWritesIt()
    {
        var payload = LicenseTestKeys.Payload(email: "jos\xe9@example.com");

        Assert.Contains("\"email\":\"jos\xe9@example.com\"", Canonical(payload), StringComparison.Ordinal);
        Assert.Contains("\"email\":\"jos\\u00e9@example.com\"", Canonical(payload, escapeNonAscii: true), StringComparison.Ordinal);
    }

    [Fact]
    public void TheSignedPayloadReadsBackFromTheServersJson()
    {
        const string body = """
            {"data":{"billing_cycle":null,"license_key":"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE","email":"user@example.com","status":"active","expires_at":null,"issued_at":"2026-01-01T00:00:00Z","tier":"team","team_id":"01JXYZ","role":"member"},"signature":"c2ln"}
            """;

        var signed = JsonSerializer.Deserialize<SignedLicensePayload>(body)!;

        Assert.Equal("team", signed.Data.Tier);
        Assert.Equal("01JXYZ", signed.Data.TeamId);
        Assert.Null(signed.Data.MachineId);
        Assert.Equal("c2ln", signed.Signature);
    }

    [Fact]
    public void APayloadMissingARequiredValueIsRefused()
    {
        const string body = """{"data":{"license_key":"K","email":"e","status":"active","issued_at":"2026-01-01T00:00:00Z"},"signature":"c2ln"}""";

        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<SignedLicensePayload>(body));
    }
}
