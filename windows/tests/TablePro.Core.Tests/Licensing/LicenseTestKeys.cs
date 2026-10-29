using System.Security.Cryptography;
using TablePro.Core.Licensing;

namespace TablePro.Core.Tests.Licensing;

/// <summary>A key pair made for the test run, standing in for the license server's signer.</summary>
internal sealed class LicenseTestKeys : IDisposable
{
    private readonly RSA _rsa = RSA.Create(2048);

    public string PublicKeyPem => _rsa.ExportSubjectPublicKeyInfoPem();

    public SignedLicensePayload Sign(LicensePayload data, bool escapeNonAscii = false) => new()
    {
        Data = data,
        Signature = Convert.ToBase64String(_rsa.SignData(data.CanonicalJson(escapeNonAscii), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)),
    };

    public static LicensePayload Payload(
        string status = "active",
        string tier = "starter",
        string? expiresAt = null,
        string issuedAt = "2026-01-01T00:00:00Z",
        string email = "user@example.com",
        string licenseKey = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
        string? billingCycle = null,
        string? teamId = null,
        string? role = null,
        string? machineId = null) => new()
        {
            BillingCycle = billingCycle,
            LicenseKey = licenseKey,
            Email = email,
            Status = status,
            ExpiresAt = expiresAt,
            IssuedAt = issuedAt,
            Tier = tier,
            TeamId = teamId,
            Role = role,
            MachineId = machineId,
        };

    public void Dispose() => _rsa.Dispose();
}
