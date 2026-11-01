using TablePro.Core.Licensing;

namespace TablePro.Core.Tests.Licensing;

public sealed class LicenseSignatureTests
{
    [Fact]
    public void APayloadSignedWithTheKeyVerifies()
    {
        using var keys = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier(keys.PublicKeyPem);
        var signed = keys.Sign(LicenseTestKeys.Payload(email: "dev/ops@example.com", tier: "team", teamId: "01JXYZ", role: "owner"));

        Assert.Equal(signed.Data, verifier.Verify(signed));
    }

    [Fact]
    public void ChangingAnySignedValueBreaksTheSignature()
    {
        using var keys = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier(keys.PublicKeyPem);
        var signed = keys.Sign(LicenseTestKeys.Payload(tier: "starter"));
        var forged = signed with { Data = signed.Data with { Tier = "team" } };

        var error = Assert.Throws<LicenseException>(() => verifier.Verify(forged));
        Assert.Equal(LicenseErrorKind.SignatureInvalid, error.Kind);
    }

    [Fact]
    public void AddingAMachineBindingBreaksTheSignature()
    {
        using var keys = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier(keys.PublicKeyPem);
        var signed = keys.Sign(LicenseTestKeys.Payload());

        Assert.Throws<LicenseException>(() => verifier.Verify(signed with { Data = signed.Data with { MachineId = "elsewhere" } }));
    }

    [Fact]
    public void AnotherKeysSignatureIsRefused()
    {
        using var keys = new LicenseTestKeys();
        using var other = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier(other.PublicKeyPem);

        Assert.Throws<LicenseException>(() => verifier.Verify(keys.Sign(LicenseTestKeys.Payload())));
    }

    [Fact]
    public void ASignatureThatIsNotBase64IsRefused()
    {
        using var keys = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier(keys.PublicKeyPem);
        var signed = keys.Sign(LicenseTestKeys.Payload()) with { Signature = "not base64!" };

        Assert.Equal(LicenseErrorKind.SignatureInvalid, Assert.Throws<LicenseException>(() => verifier.Verify(signed)).Kind);
    }

    [Fact]
    public void ASignatureOverPhpEscapedUnicodeVerifies()
    {
        using var keys = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier(keys.PublicKeyPem);
        var signed = keys.Sign(LicenseTestKeys.Payload(email: "jos\xe9@example.com"), escapeNonAscii: true);

        Assert.Equal(signed.Data, verifier.Verify(signed));
    }

    [Fact]
    public void AnUnreadableKeyVerifiesNothing()
    {
        using var keys = new LicenseTestKeys();
        using var verifier = new LicenseSignatureVerifier("-----BEGIN PUBLIC KEY-----\nnot a key\n-----END PUBLIC KEY-----");

        Assert.False(verifier.HasKey);
        Assert.Equal(LicenseErrorKind.PublicKeyInvalid, Assert.Throws<LicenseException>(() => verifier.Verify(keys.Sign(LicenseTestKeys.Payload()))).Kind);
    }

    [Fact]
    public void TheProductionKeyLoads()
    {
        using var verifier = new LicenseSignatureVerifier();

        Assert.True(verifier.HasKey);
    }
}
