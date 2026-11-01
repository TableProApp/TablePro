using System.Globalization;
using System.Security.Cryptography;
using TablePro.Core.Licensing;
using TablePro.Storage.Library.Team;
using TablePro.Storage.Licensing;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Tests.Licensing;

/// <summary>The team library shows only while a Team license grants it, as the macOS coordinator follows the license.</summary>
public sealed class TeamLibraryLicenseTests : IDisposable
{
    private const string Key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE";
    private const string Machine = "machine";

    private readonly TempDirectory _temp = new();
    private readonly RSA _signer = RSA.Create(2048);
    private readonly FakeLicenseApi _licenseApi = new();
    private readonly TeamApi _teamApi = new();

    public void Dispose()
    {
        _signer.Dispose();
        _temp.Dispose();
    }

    private SignedLicensePayload Signed(string tier, string status = "active")
    {
        var data = new LicensePayload
        {
            LicenseKey = Key,
            Email = "user@example.com",
            Status = status,
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

    private (LicenseService License, TeamLibrarySync Team, TeamLibraryStore Store) Create()
    {
        var license = new LicenseService(
            _licenseApi,
            new LicenseStore(_temp.Paths, new InMemorySecretStore()),
            new FixedMachineIdentity(Machine, "DESKTOP"),
            new LicenseSignatureVerifier(_signer.ExportSubjectPublicKeyInfoPem()),
            new LicenseClientInfo("1.0.0", "Windows"));
        var store = new TeamLibraryStore(_temp.Paths);
        var team = new TeamLibrarySync(_teamApi, store, () => license.IsFeatureAvailable(ProFeature.TeamLibrary) && license.License is { } held ? new TeamLibraryCredentials(held.Key, license.MachineId) : null);
        team.Follow(license);
        return (license, team, store);
    }

    [Fact]
    public async Task ATeamLicensePullsTheLibraryAndDeactivatingClearsIt()
    {
        var (license, team, store) = Create();
        using var _ = license;
        using var __ = store;
        Assert.False(team.IsAvailable);

        var pulled = new TaskCompletionSource();
        team.Changed += (_, _) =>
        {
            if (!team.Library.IsEmpty)
            {
                pulled.TrySetResult();
            }
        };
        _licenseApi.Activate = _ => Signed("team");
        await license.ActivateAsync(Key, TestContext.Current.CancellationToken);
        await pulled.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);

        Assert.True(team.IsAvailable);
        Assert.Equal(Key, _teamApi.LastCredentials?.LicenseKey);
        Assert.Equal(Machine, _teamApi.LastCredentials?.MachineId);

        var cleared = new TaskCompletionSource();
        team.Changed += (_, _) =>
        {
            if (team.Library.IsEmpty)
            {
                cleared.TrySetResult();
            }
        };
        await license.DeactivateAsync(TestContext.Current.CancellationToken);
        await cleared.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);

        Assert.False(team.IsAvailable);
        Assert.False(File.Exists(_temp.File("team_library.json")));
    }

    [Fact]
    public async Task AStarterLicenseDoesNotGrantTheTeamLibrary()
    {
        var (license, team, store) = Create();
        using var _ = license;
        using var __ = store;
        _licenseApi.Activate = _ => Signed("starter");

        await license.ActivateAsync(Key, TestContext.Current.CancellationToken);

        Assert.False(team.IsAvailable);
        Assert.Equal(0, _teamApi.PullCount);
    }

    private sealed class TeamApi : ITeamLibraryApiClient
    {
        public int PullCount { get; private set; }

        public TeamLibraryCredentials? LastCredentials { get; private set; }

        public Task<TeamLibraryPullResponse> PullAsync(TeamLibraryCredentials credentials, CancellationToken cancellationToken = default)
        {
            PullCount++;
            LastCredentials = credentials;
            var response = new TeamLibraryPullResponse([], [], [new TeamLibraryQuery("Q", null, null, "Recent", "select 1", null, 0, "owner@example.com")], "now");
            return Task.FromResult(response);
        }

        public Task<TeamLibraryPublishResponse> PublishAsync(TeamLibraryPublishRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(new TeamLibraryPublishResponse("now", 0, 0));

        public Task DeleteConnectionAsync(string id, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task DeleteQueryAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task DeleteQueryFolderAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
}
