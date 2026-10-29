using System.Globalization;
using System.Security.Cryptography;
using TablePro.Core.Licensing;
using TablePro.Storage.Licensing;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Tests.Licensing;

/// <summary>A paid feature's gate follows the license while a window is open, against a fake license server.</summary>
public sealed class ProFeatureMonitorTests : IDisposable
{
    private const string Key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE";
    private const string Machine = "machine";

    private readonly TempDirectory _temp = new();
    private readonly RSA _signer = RSA.Create(2048);
    private readonly FakeLicenseApi _api = new();

    public void Dispose()
    {
        _signer.Dispose();
        _temp.Dispose();
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private LicenseService CreateService() => new(
        _api,
        new LicenseStore(_temp.Paths, new InMemorySecretStore()),
        new FixedMachineIdentity(Machine, "DESKTOP"),
        new LicenseSignatureVerifier(_signer.ExportSubjectPublicKeyInfoPem()),
        new LicenseClientInfo("1.0.0", "Windows"));

    private SignedLicensePayload Signed(string tier)
    {
        var data = new LicensePayload
        {
            LicenseKey = Key,
            Email = "user@example.com",
            Status = "active",
            IssuedAt = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ssK", CultureInfo.InvariantCulture),
            Tier = tier,
            TeamId = tier == "team" ? "01JXYZ" : null,
            MachineId = Machine,
        };
        return new SignedLicensePayload
        {
            Data = data,
            Signature = Convert.ToBase64String(_signer.SignData(data.CanonicalJson(), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)),
        };
    }

    [Fact]
    public async Task ActivatingUnlocksAndDeactivatingLocksAnOpenGate()
    {
        using var license = CreateService();
        using var charts = new ProFeatureMonitor(license, ProFeature.ResultCharts);
        var changes = 0;
        charts.AccessChanged += (_, _) => changes++;
        Assert.Equal(ProFeatureAccessKind.Unlicensed, charts.Access.Kind);

        _api.Activate = _ => Signed("starter");
        await license.ActivateAsync(Key, Ct);

        Assert.True(charts.IsAvailable);
        Assert.Equal(1, changes);

        await license.DeactivateAsync(Ct);

        Assert.False(charts.IsAvailable);
        Assert.Equal(2, changes);
    }

    [Fact]
    public async Task LicenseChangesThatLeaveAccessAloneRaiseNothing()
    {
        using var license = CreateService();
        _api.Activate = _ => Signed("starter");
        await license.ActivateAsync(Key, Ct);
        using var rewind = new ProFeatureMonitor(license, ProFeature.DataRewind);
        var changes = 0;
        rewind.AccessChanged += (_, _) => changes++;

        // A device list load announces each of its steps through Changed; none of them touches entitlement.
        _api.Activations = _ => throw new LicenseException(LicenseErrorKind.Network, "offline");
        await license.LoadDevicesAsync(force: true, Ct);

        Assert.True(rewind.IsAvailable);
        Assert.Equal(0, changes);
    }

    [Fact]
    public async Task AStarterLicenseUnlocksTheStarterFeaturesButNotTheTeamLibrary()
    {
        using var license = CreateService();
        using var compare = new ProFeatureMonitor(license, ProFeature.CompareSync);
        using var export = new ProFeatureMonitor(license, ProFeature.EncryptedExport);
        using var team = new ProFeatureMonitor(license, ProFeature.TeamLibrary);

        _api.Activate = _ => Signed("starter");
        await license.ActivateAsync(Key, Ct);

        Assert.True(compare.IsAvailable);
        Assert.True(export.IsAvailable);
        Assert.Equal(new ProFeatureAccess(ProFeatureAccessKind.RequiresUpgrade, LicenseTier.Team), team.Access);
    }

    [Fact]
    public async Task ADisposedMonitorStopsFollowingTheLicense()
    {
        using var license = CreateService();
        var charts = new ProFeatureMonitor(license, ProFeature.ResultCharts);
        var changes = 0;
        charts.AccessChanged += (_, _) => changes++;
        charts.Dispose();

        _api.Activate = _ => Signed("starter");
        await license.ActivateAsync(Key, Ct);

        Assert.Equal(0, changes);
    }
}
