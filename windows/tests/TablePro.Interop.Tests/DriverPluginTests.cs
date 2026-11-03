using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace TablePro.Interop.Tests;

// windows.yml builds the SQLite driver library, signs a copy with a test certificate the runner trusts, and names
// both here; elsewhere only the refusals run.
public sealed class DriverPluginTests : IDisposable
{
    private static readonly string? Signed = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER");
    private static readonly string? Unsigned = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER_UNSIGNED");
    private static readonly string? Subject = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER_SIGNER");
    private static readonly string? Issuer = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER_SIGNER_ISSUER");
    private static readonly DriverSigner ProductionSigner = new("CN=TablePro", new string('0', 64));

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-drivers-").FullName;

    public void Dispose()
    {
        // A loaded driver is never unloaded, so Windows keeps its file until the test host exits.
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (UnauthorizedAccessException)
        {
        }
        catch (IOException)
        {
        }
    }

    private static DriverSigner TestSigner => new(Subject!, Issuer!);

    private TableProCore Core(params DriverSigner[] signers) =>
        TableProCore.Create(new HostConfiguration("test", _directory, signers), new MemorySecretStore());

    private static void NeedsSignedDriver() =>
        Assert.SkipUnless(
            Signed is not null && Unsigned is not null && Subject is not null && Issuer is not null,
            "windows.yml signs the test driver");

    private static string Os =>
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux";

    private static string Arch => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "aarch64" : "x86_64";

    private static string Catalog(string version, string sha256, string arch) => $$"""
        {"schemaVersion": 1, "plugins": [{"id": "sqlite", "name": "SQLite", "databaseTypeIds": ["sqlite"],
          "releases": [{"version": "{{version}}", "build": 1, "channel": "stable", "abi": 1, "os": "{{Os}}",
            "arch": "{{arch}}", "url": "https://example.com/sqlite.dll", "sha256": "{{sha256}}"}]}]}
        """;

    private static string Sha256(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));

    [Fact]
    public async Task ANewDataFolderHasNoDrivers()
    {
        using var core = Core(ProductionSigner);

        Assert.Empty(await core.Drivers.GetInstalledAsync());
    }

    [Fact]
    public async Task AFileWithNoSignatureIsRefusedAndLeavesNothingInstalled()
    {
        using var core = Core(ProductionSigner);
        var file = Path.Combine(_directory, "driver.dll");
        await File.WriteAllBytesAsync(file, [0x4D, 0x5A]);

        var refused = await Assert.ThrowsAsync<TableProException>(() => core.Drivers.InstallFileAsync(file));

        Assert.Equal(OperatingSystem.IsWindows() ? "plugin.unsigned" : "plugin.trust_unavailable", refused.Code);
        Assert.Empty(await core.Drivers.GetInstalledAsync());
    }

    [Fact]
    public void ACatalogListsOnlyTheReleaseForThisProcessor()
    {
        var other = Arch == "x86_64" ? "aarch64" : "x86_64";

        var here = DriverPlugins.Available(Catalog("0.1.0", "ab", Arch));
        var elsewhere = DriverPlugins.Available(Catalog("0.1.0", "ab", other));

        var driver = Assert.Single(here);
        Assert.Equal(("sqlite", "SQLite", "0.1.0"), (driver.Id, driver.Name, driver.Version));
        Assert.Empty(elsewhere);
        Assert.Equal("plugin.manifest_invalid", Assert.Throws<TableProException>(() => DriverPlugins.Available("<html>")).Code);
    }

    [Fact]
    public async Task ASignedDriverInstallsLoadsAgainAfterARestartAndGoesWhenRemoved()
    {
        NeedsSignedDriver();
        using (var core = Core(TestSigner))
        {
            var installed = await core.Drivers.InstallFileAsync(Signed!);

            Assert.True(installed.IsLoaded, installed.Error?.Message);
            Assert.Equal("sqlite", installed.Id);
            Assert.Equal("SQLite", installed.Name);
            Assert.Equal("1.0", installed.AbiVersion);
            Assert.StartsWith(_directory, installed.Path, StringComparison.OrdinalIgnoreCase);
        }

        using var restarted = Core(TestSigner);
        var listed = Assert.Single(await restarted.Drivers.GetInstalledAsync());
        Assert.True(listed.IsLoaded, listed.Error?.Message);

        await restarted.Drivers.RemoveAsync("sqlite");

        Assert.Empty(await restarted.Drivers.GetInstalledAsync());
    }

    [Fact]
    public async Task ADriverSignedBySomeoneElseOrNotAtAllIsRefused()
    {
        NeedsSignedDriver();
        using var core = Core(ProductionSigner);

        var otherSigner = await Assert.ThrowsAsync<TableProException>(() => core.Drivers.InstallFileAsync(Signed!));
        var noSignature = await Assert.ThrowsAsync<TableProException>(() => core.Drivers.InstallFileAsync(Unsigned!));

        Assert.Equal("plugin.wrong_signer", otherSigner.Code);
        Assert.Equal("plugin.unsigned", noSignature.Code);
        Assert.Empty(await core.Drivers.GetInstalledAsync());
    }

    [Fact]
    public async Task ACatalogReleaseInstallsOnlyWhenTheDownloadMatchesItsChecksum()
    {
        NeedsSignedDriver();
        using var core = Core(TestSigner);
        var installed = await core.Drivers.InstallFileAsync(Signed!);
        var version = installed.Version;

        var tampered = await Assert.ThrowsAsync<TableProException>(
            () => core.Drivers.InstallReleaseAsync(Catalog(version, new string('0', 64), Arch), "sqlite", Signed!));
        var release = await core.Drivers.InstallReleaseAsync(Catalog(version, Sha256(Signed!), Arch), "sqlite", Signed!);

        Assert.Equal("plugin.checksum_mismatch", tampered.Code);
        Assert.True(release.IsLoaded, release.Error?.Message);
        Assert.NotEqual(installed.Path, release.Path);
    }
}
