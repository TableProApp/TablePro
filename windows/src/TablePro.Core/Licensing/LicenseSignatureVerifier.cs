using System.Security.Cryptography;

namespace TablePro.Core.Licensing;

/// <summary>
/// Checks the server's RSA-SHA256 (PKCS#1 v1.5) signature over a payload's canonical JSON with the public key the
/// macOS app ships. Tests pass a generated key instead, so no test depends on the production signer.
/// </summary>
public sealed class LicenseSignatureVerifier : IDisposable
{
    /// <summary>The production public key, the macOS app's <c>license_public.pem</c>. It verifies only; it cannot sign.</summary>
    public const string ProductionPublicKeyPem = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxjWFYYuLeIkiF8LdsV2h
        7zN/nItAYs8Zfve7QlBIbghkz1gU2v7E510aaVCGeGBcOv6OWdVfl7qQCNxmVxyy
        kn5s4nsdWLYt7z8Y5rYC8qF/NWyu+uzyofXH5matfm7uOvJYyh8jetmoOTQBhoZX
        2TVjt76DV04Nwd3z+VsckEcZUgezVQKACcP9IjoT9qX7xv0XNK7Ycvi1IibXLHMX
        TnUAJKE2RQTWZzGhVT7+YZVSXowFccMF0InK5oZq8RcM3z6enxsY2h04bx/3F+Gg
        ukWwL61y8lxo1MerOzABXiA2h8Nqki9wwuKo2RlJyGLUfkrY49PlkW5eKOsn7dhX
        MQIDAQAB
        -----END PUBLIC KEY-----
        """;

    private readonly RSA? _key;

    /// <param name="publicKeyPem">A PEM <c>PUBLIC KEY</c>. An unreadable key leaves every payload unverified rather than throwing at startup.</param>
    public LicenseSignatureVerifier(string publicKeyPem = ProductionPublicKeyPem)
    {
        var key = RSA.Create();
        try
        {
            key.ImportFromPem(publicKeyPem);
            _key = key;
        }
        catch (Exception ex) when (ex is ArgumentException or CryptographicException)
        {
            key.Dispose();
        }
    }

    /// <summary>Whether a key loaded; without one nothing verifies.</summary>
    public bool HasKey => _key is not null;

    /// <summary>Returns the payload's data when the signature is the server's.</summary>
    /// <exception cref="LicenseException">The signature does not match, or no key loaded.</exception>
    public LicensePayload Verify(SignedLicensePayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        if (_key is null)
        {
            throw new LicenseException(LicenseErrorKind.PublicKeyInvalid, "The license public key could not be read.");
        }

        var signature = new byte[payload.Signature.Length];
        if (!Convert.TryFromBase64String(payload.Signature, signature, out var length))
        {
            throw new LicenseException(LicenseErrorKind.SignatureInvalid, "The license signature is not base64.");
        }

        var data = payload.Data;
        var valid = Verify(data.CanonicalJson(), signature.AsSpan(0, length))
            // The server's json_encode escapes non-ASCII characters while the macOS verifier writes them as UTF-8.
            // Both encodings are deterministic functions of the same signed values, so accepting either opens nothing.
            || (data.HasNonAscii() && Verify(data.CanonicalJson(escapeNonAscii: true), signature.AsSpan(0, length)));

        return valid ? data : throw new LicenseException(LicenseErrorKind.SignatureInvalid, "The license signature does not match.");
    }

    private bool Verify(byte[] data, ReadOnlySpan<byte> signature) =>
        _key!.VerifyData(data, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

    public void Dispose() => _key?.Dispose();
}
