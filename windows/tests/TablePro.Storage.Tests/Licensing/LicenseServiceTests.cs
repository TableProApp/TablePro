using System.Globalization;
using System.Security.Cryptography;
using TablePro.Core.Licensing;
using TablePro.Storage.Licensing;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Tests.Licensing;

public sealed class LicenseServiceTests : IDisposable
{
    private const string Key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE";
    private const string ThisMachine = "this-machine";

    private readonly TempDirectory _temp = new();
    private readonly RSA _signer = RSA.Create(2048);
    private readonly ManualClock _clock =new(new DateTimeOffset(2026, 6, 15, 12, 0, 0, TimeSpan.Zero));
    private readonly InMemorySecretStore _secrets = new();
    private readonly FakeLicenseApi _api = new();

    public void Dispose()
    {
        _signer.Dispose();
        _temp.Dispose();
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private LicenseStore Store => new(_temp.Paths, _secrets);

    private LicenseService CreateService(string machine = ThisMachine) => new(
        _api,
        Store,
        new FixedMachineIdentity(machine, "DESKTOP-TEST"),
        new LicenseSignatureVerifier(_signer.ExportSubjectPublicKeyInfoPem()),
        new LicenseClientInfo("1.0.0", "Microsoft Windows 10.0.26200"),
        _clock);

    private string Date(int daysFromNow) => _clock.GetUtcNow().AddDays(daysFromNow).ToString("yyyy-MM-dd'T'HH:mm:ssK", CultureInfo.InvariantCulture);

    private SignedLicensePayload Signed(string tier = "starter", string status = "active", string? machineId = ThisMachine, int issuedDaysAgo = 0, string? teamId = null, string? expiresAt = null)
    {
        var data = new LicensePayload
        {
            LicenseKey = Key,
            Email = "user@example.com",
            Status = status,
            IssuedAt = Date(-issuedDaysAgo),
            ExpiresAt = expiresAt,
            Tier = tier,
            TeamId = teamId,
            Role = teamId is null ? null : "member",
            MachineId = machineId,
        };
        return new SignedLicensePayload
        {
            Data = data,
            Signature = Convert.ToBase64String(_signer.SignData(data.CanonicalJson(), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)),
        };
    }

    [Fact]
    public async Task ActivatingStoresTheKeyAsASecretAndThePayloadOnDisk()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed("team", teamId: "01JXYZ");
        var statusChanges = 0;
        service.StatusChanged += (_, _) => statusChanges++;

        await service.ActivateAsync(" aaaaa-bbbbb-ccccc-ddddd-eeeee ", Ct);

        Assert.Equal(Key, _api.LastRequest?.LicenseKey);
        Assert.Equal(ThisMachine, _api.LastRequest?.MachineId);
        Assert.Equal("DESKTOP-TEST", _api.LastRequest?.MachineName);
        Assert.Equal(LicenseStatus.Active, service.Status);
        Assert.Equal(1, statusChanges);
        Assert.True(service.IsFeatureAvailable(ProFeature.TeamLibrary));
        Assert.Equal(Key, _secrets.Get(LicenseStore.KeySecret));
        Assert.True(File.Exists(_temp.File("license.json")));
    }

    [Fact]
    public async Task AnythingThatIsNotAKeyIsSentAsAnInviteCode()
    {
        using var service = CreateService();
        _api.AcceptInvite = _ => Signed("team", teamId: "01JXYZ");

        await service.ActivateAsync("01JXYZINVITE", Ct);

        Assert.Equal("01JXYZINVITE", _api.LastInvite?.Token);
        Assert.Equal(Key, _secrets.Get(LicenseStore.KeySecret));
        Assert.True(service.License!.IsTeamLicense);
    }

    [Fact]
    public async Task APayloadMintedForAnotherMachineIsRefusedAndNothingIsStored()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed(machineId: "elsewhere");

        var error = await Assert.ThrowsAsync<LicenseException>(() => service.ActivateAsync(Key, Ct));

        Assert.Equal(LicenseErrorKind.MachineMismatch, error.Kind);
        Assert.Equal(LicenseStatus.Unlicensed, service.Status);
        Assert.Null(_secrets.Get(LicenseStore.KeySecret));
        Assert.Same(error, service.LastError);
    }

    [Fact]
    public async Task AForgedSignatureIsRefused()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed() with { Signature = Convert.ToBase64String(new byte[256]) };

        Assert.Equal(LicenseErrorKind.SignatureInvalid, (await Assert.ThrowsAsync<LicenseException>(() => service.ActivateAsync(Key, Ct))).Kind);
    }

    [Fact]
    public async Task TheCachedLicenseIsVerifiedAgainAtStart()
    {
        using (var first = CreateService())
        {
            _api.Activate = _ => Signed("team", teamId: "01JXYZ");
            await first.ActivateAsync(Key, Ct);
        }

        using var second = CreateService();
        await second.LoadAsync(Ct);

        Assert.Equal(LicenseStatus.Active, second.Status);
        Assert.Equal(LicenseTier.Team, second.CurrentTier);
    }

    [Fact]
    public async Task ACacheTamperedWithOnDiskIsDropped()
    {
        using (var first = CreateService())
        {
            _api.Activate = _ => Signed("starter");
            await first.ActivateAsync(Key, Ct);
        }

        var path = _temp.File("license.json");
        await File.WriteAllTextAsync(path, (await File.ReadAllTextAsync(path, Ct)).Replace("\"starter\"", "\"team\"", StringComparison.Ordinal), Ct);
        using var second = CreateService();
        await second.LoadAsync(Ct);

        Assert.Equal(LicenseStatus.Unlicensed, second.Status);
        Assert.False(File.Exists(path));
        Assert.Null(_secrets.Get(LicenseStore.KeySecret));
    }

    [Fact]
    public async Task ACacheCopiedFromAnotherMachineIsDropped()
    {
        using (var first = CreateService())
        {
            _api.Activate = _ => Signed(machineId: null);
            await first.ActivateAsync(Key, Ct);
        }

        using var second = CreateService(machine: "another-machine");
        await second.LoadAsync(Ct);

        Assert.Equal(LicenseStatus.Unlicensed, second.Status);
    }

    [Fact]
    public async Task OfflineGraceRunsThirtyDaysFromTheSignedIssueDate()
    {
        using (var first = CreateService())
        {
            _api.Activate = _ => Signed(issuedDaysAgo: 30);
            await first.ActivateAsync(Key, Ct);
        }

        using var service = CreateService();
        await service.LoadAsync(Ct);
        Assert.Equal(LicenseStatus.Active, service.Status);

        _clock.Advance(TimeSpan.FromDays(1));
        _api.Validate = _ => throw new LicenseException(LicenseErrorKind.Network, "offline");
        await service.RevalidateAsync(Ct);

        Assert.Equal(LicenseStatus.ValidationFailed, service.Status);
        Assert.Equal(ProFeatureAccessKind.ValidationFailed, service.CheckFeature(ProFeature.ResultCharts).Kind);
        Assert.Equal(SupportAudience.Supporter, service.SupportAudience);
    }

    [Fact]
    public async Task AServerThatConfirmedThisSessionKeepsAStaleIssueDateFromFailingGrace()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed(issuedDaysAgo: 45);
        await service.ActivateAsync(Key, Ct);

        Assert.Equal(LicenseStatus.Active, service.Status);
    }

    [Fact]
    public async Task ARejectionTheServerSpeaksRevokesButATransportFailureDoesNot()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed();
        await service.ActivateAsync(Key, Ct);

        _api.Validate = _ => throw new LicenseException(LicenseErrorKind.Network, "offline");
        await service.RevalidateAsync(Ct);
        Assert.Equal(LicenseStatus.Active, service.Status);

        _api.Validate = _ => throw new LicenseException(LicenseErrorKind.LicenseSuspended, "suspended");
        await service.RevalidateAsync(Ct);
        Assert.Equal(LicenseStatus.Suspended, service.Status);
        Assert.False(service.IsFeatureAvailable(ProFeature.DataRewind));

        var confirmed = 0;
        service.Confirmed += (_, _) => confirmed++;
        _api.Validate = _ => Signed("team", teamId: "01JXYZ");
        await service.RevalidateAsync(Ct);
        Assert.Equal(LicenseStatus.Active, service.Status);
        Assert.Equal(1, confirmed);
        Assert.Equal(LicenseTier.Team, service.CurrentTier);
    }

    [Fact]
    public async Task DeactivatingRemovesTheLicenseEvenWhenTheServerCannotBeReached()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed();
        await service.ActivateAsync(Key, Ct);
        _api.Deactivate = _ => throw new LicenseException(LicenseErrorKind.Network, "offline");
        var removed = 0;
        service.Removed += (_, _) => removed++;

        var reachedServer = await service.DeactivateAsync(Ct);

        Assert.False(reachedServer);
        Assert.Equal(1, removed);
        Assert.Equal(LicenseStatus.Deactivated, service.Status);
        Assert.Null(service.License);
        Assert.Null(_secrets.Get(LicenseStore.KeySecret));
        Assert.False(File.Exists(_temp.File("license.json")));
        Assert.Equal(LicenseErrorKind.SeatReleaseUnconfirmed, service.ReleaseError?.Kind);
    }

    [Fact]
    public async Task ReleasingAnotherMachineKeepsThisOneAndDropsOnlyThatRow()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed();
        await service.ActivateAsync(Key, Ct);
        var other = new LicenseActivation("other", "LAPTOP", "1.0.0", "macOS 15", null, Date(-3));
        _api.Activations = _ => new LicenseActivations([new LicenseActivation(ThisMachine, "DESKTOP-TEST", "1.0.0", "Windows", null, Date(-1)), other], 3);
        await service.LoadDevicesAsync(cancellationToken: Ct);
        Assert.Equal(LicenseListState.Loaded, service.DeviceListState);
        Assert.Equal(3, service.MaxDevices);
        Assert.True(service.CanReleaseOtherDevices);

        await service.ReleaseDeviceAsync(other, Ct);

        Assert.Equal("other", _api.LastDeactivation?.MachineId);
        Assert.Equal(LicenseStatus.Active, service.Status);
        Assert.Equal([ThisMachine], service.Devices.Select(d => d.MachineId));
        Assert.False(service.IsReleasing("other"));
    }

    [Fact]
    public async Task AFailedReleaseKeepsTheListAndReportsBesideIt()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed();
        await service.ActivateAsync(Key, Ct);
        var other = new LicenseActivation("other", "LAPTOP", "1.0.0", "macOS 15", null, Date(-3));
        _api.Activations = _ => new LicenseActivations([other], 3);
        await service.LoadDevicesAsync(cancellationToken: Ct);
        _api.Deactivate = _ => throw new LicenseException(LicenseErrorKind.Server, "nope", statusCode: 500);

        await service.ReleaseDeviceAsync(other, Ct);

        Assert.Single(service.Devices);
        Assert.Equal(LicenseErrorKind.Server, service.ReleaseError?.Kind);
    }

    [Fact]
    public async Task ARefreshThatFailsLeavesTheLoadedSeatsAlone()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed();
        await service.ActivateAsync(Key, Ct);
        _api.Activations = _ => new LicenseActivations([new LicenseActivation(ThisMachine, "DESKTOP-TEST", "1.0.0", "Windows", null, Date(-1))], 3);
        await service.LoadDevicesAsync(cancellationToken: Ct);
        _api.Activations = _ => throw new LicenseException(LicenseErrorKind.Network, "offline");

        await service.LoadDevicesAsync(force: true, cancellationToken: Ct);

        Assert.Equal(LicenseListState.Loaded, service.DeviceListState);
        Assert.Single(service.Devices);
        Assert.Equal(LicenseErrorKind.Network, service.RefreshError?.Kind);
    }

    [Fact]
    public async Task ATeamLicenseCannotReleaseTeammatesButReadsItsRoster()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed("team", teamId: "01JXYZ");
        await service.ActivateAsync(Key, Ct);
        _api.Team = _ => new LicenseTeam([new LicenseTeamMember("user@example.com", "owner", null)], 1, 5);

        await service.LoadTeamAsync(cancellationToken: Ct);

        Assert.False(service.CanReleaseOtherDevices);
        Assert.True(service.ShowsTeamRoster);
        Assert.Equal(LicenseListState.Loaded, service.TeamListState);
        Assert.Equal(5, service.Team?.MaxSeats);
    }

    [Fact]
    public async Task AStarterLicenseHasNoRosterAndNeedsAnUpgradeForTheTeamLibrary()
    {
        using var service = CreateService();
        _api.Activate = _ => Signed("starter");
        await service.ActivateAsync(Key, Ct);

        await service.LoadTeamAsync(cancellationToken: Ct);

        Assert.False(service.ShowsTeamRoster);
        Assert.Equal(LicenseListState.Idle, service.TeamListState);
        Assert.Equal(new ProFeatureAccess(ProFeatureAccessKind.RequiresUpgrade, LicenseTier.Team), service.CheckFeature(ProFeature.TeamLibrary));
    }

    [Fact]
    public async Task APeriodicCheckRunsAtStartWhenAWeekHasPassed()
    {
        using (var first = CreateService())
        {
            _api.Activate = _ => Signed(issuedDaysAgo: 8);
            await first.ActivateAsync(Key, Ct);
        }

        using var service = CreateService();
        await service.LoadAsync(Ct);
        var validated = new TaskCompletionSource();
        _api.Validate = _ =>
        {
            validated.TrySetResult();
            return Signed();
        };

        service.StartPeriodicValidation();

        await validated.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
    }

    private sealed class ManualClock(DateTimeOffset start) : TimeProvider
    {
        private DateTimeOffset _now = start;

        public override DateTimeOffset GetUtcNow() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
