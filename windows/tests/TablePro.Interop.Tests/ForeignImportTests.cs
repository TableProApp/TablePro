using System.Security.Cryptography;
using System.Text;

namespace TablePro.Interop.Tests;

public sealed class ForeignImportTests : IDisposable
{
    // DBeaver encrypts every project's credentials with this one key.
    private static readonly byte[] DBeaverKey =
        [0xBA, 0xBB, 0x4A, 0x9F, 0x77, 0x4A, 0xB8, 0x53, 0xC9, 0x6C, 0x2D, 0x65, 0x3D, 0xFE, 0x54, 0x4A];

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-foreign-").FullName;
    private readonly MemorySecretStore _secrets = new();
    private readonly TableProCore _core;
    private readonly ForeignAppDirs _dirs;

    public ForeignImportTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", Path.Combine(_directory, "storage")), _secrets);
        _dirs = new ForeignAppDirs(_directory, Path.Combine(_directory, "config"), Path.Combine(_directory, "data"));
    }

    public void Dispose()
    {
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // The history database closes on the core's own threads, which can still hold it here on Windows.
        }
    }

    [Fact]
    public async Task AnImportedConnectionLandsInTheProjectGiven()
    {
        WriteDBeaver();
        var acme = await _core.Library.CreateProjectAsync("Acme");
        using var review = await _core.ReadForeignAsync(
            ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, true), TestContext.Current.CancellationToken);

        await review.ApplyAsync(acme.Id);

        var saved = Assert.Single((await _core.Library.GetSnapshotAsync(acme.Id)).Connections);
        Assert.Equal(acme.Id, saved.ProjectId);
    }

    [Fact]
    public async Task ADBeaverConnectionLandsWithItsPasswordAndItsScriptOnce()
    {
        WriteDBeaver();

        var sources = await _core.GetForeignSourcesAsync(_dirs);
        using var review = await _core.ReadForeignAsync(
            ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, true), TestContext.Current.CancellationToken);
        var choices = review.Choices();
        var outcome = await review.ApplyAsync();
        var again = await Assert.ThrowsAsync<TableProException>(() => review.ApplyAsync());
        var saved = (await _core.Library.GetSnapshotAsync()).Connections.Single();

        var dbeaver = sources.Single(source => source.App == ForeignApp.DBeaver);
        Assert.True(dbeaver.IsAvailable);
        Assert.Equal(ForeignSourceAvailability.Available.Instance, dbeaver.Availability);
        Assert.Equal((1, 1), (dbeaver.Connections, dbeaver.SavedQueries));
        Assert.Equal(ForeignPasswordOffer.DecryptedWhileReading, dbeaver.PasswordOffer);
        Assert.True(dbeaver.OffersSavedQueries);
        Assert.True(dbeaver.StartsTicked);
        Assert.True(dbeaver.Preselected);
        Assert.Equal(ForeignApp.DBeaver, sources.Single(source => source.Preselected).App);
        var navicat = sources.Single(source => source.App == ForeignApp.Navicat);
        Assert.True(navicat.PicksFile);
        Assert.False(navicat.StartsTicked);
        Assert.Equal(ForeignPasswordOutcome.Read, review.Passwords);
        Assert.Equal("Windows PG", review.Connections[0].Name);
        Assert.Equal("windows.example.com", review.Connections[0].Connection?.Host);
        Assert.True(choices.Connections[0].Selected);
        Assert.Equal(ForeignResolution.Add.Instance, choices.Connections[0].Resolution);
        Assert.Equal(ForeignQueryAvailability.Available, choices.Queries[0].Availability);
        Assert.Equal(
            (1, 0, 0, 1, 0, 0),
            (outcome.Connections, outcome.Replaced, outcome.PasswordsNotKept, outcome.QueriesAdded,
                outcome.QueriesAlreadySaved, outcome.QueriesFailed));
        Assert.Equal([saved.Id!.Value], outcome.ConnectionIds);
        Assert.Equal("foreign_import.applied", again.Code);
        Assert.Equal("Windows PG", saved.Name);
        Assert.Equal("windows-pass", _secrets.Load(saved.Id!.Value, SecretKind.DatabasePassword));
    }

    [Fact]
    public async Task ASecondReadMatchesTheSavedConnectionAndAnUncheckedRowWritesNothing()
    {
        WriteDBeaver();
        var cancellationToken = TestContext.Current.CancellationToken;
        using (var first = await _core.ReadForeignAsync(
            ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, false), cancellationToken))
        {
            await first.ApplyAsync();
        }

        var id = (await _core.Library.GetSnapshotAsync()).Connections.Single().Id!.Value;
        using var review = await _core.ReadForeignAsync(
            ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, false), cancellationToken);
        var before = review.Choices();
        review.SetSelected("General/windows", true);
        var offered = review.Choices().Connections[0].Offered;
        var replaced = review.Resolve("General/windows", new ForeignResolution.Replace(id));
        var outcome = await review.ApplyAsync();

        Assert.Equal(new ExistingConnection(id, "Windows PG"), review.Connections[0].Duplicate);
        Assert.False(before.Connections[0].Selected);
        Assert.False(before.Importable);
        Assert.Equal([ForeignResolution.AddCopy.Instance, new ForeignResolution.Replace(id)], offered);
        Assert.True(replaced);
        Assert.Equal(
            (1, 1, 0, 0, 0, 0),
            (outcome.Connections, outcome.Replaced, outcome.PasswordsNotKept, outcome.QueriesAdded,
                outcome.QueriesAlreadySaved, outcome.QueriesFailed));
        Assert.Equal([id], outcome.ConnectionIds);
        Assert.Single((await _core.Library.GetSnapshotAsync()).Connections);
    }

    [Fact]
    public async Task TheLaunchProbeReadsNoCountAndUnreadableDataSaysWhy()
    {
        WriteDBeaver();
        var probe = await _core.GetForeignSourcesAsync(_dirs, ForeignScanDepth.Presence);
        File.WriteAllText(Path.Combine(DBeaverProject(), ".dbeaver", "data-sources.json"), "{ not json");
        var broken = await _core.GetForeignSourcesAsync(_dirs);

        var found = probe.Single(source => source.App == ForeignApp.DBeaver);
        Assert.True(found.IsAvailable);
        Assert.Equal((0, 0), (found.Connections, found.SavedQueries));
        Assert.False(found.StartsTicked);
        var unreadable = broken.Single(source => source.App == ForeignApp.DBeaver);
        Assert.False(unreadable.IsAvailable);
        var reason = Assert.IsType<ForeignSourceAvailability.Unreadable>(unreadable.Availability);
        Assert.Equal("foreign_import.parse", reason.Code);
        Assert.False(unreadable.Preselected);
        Assert.Equal(ForeignApp.Navicat, broken.Single(source => source.Preselected).App);
    }

    [Fact]
    public async Task AKeptConnectionWritesNoId()
    {
        WriteDBeaver();
        var cancellationToken = TestContext.Current.CancellationToken;
        using (var first = await _core.ReadForeignAsync(
            ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, true), cancellationToken))
        {
            await first.ApplyAsync();
        }

        using var review = await _core.ReadForeignAsync(
            ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, true), cancellationToken);
        review.SetSelected("General/windows", true);
        var resolution = review.Choices().Connections[0].Resolution;
        var outcome = await review.ApplyAsync();

        Assert.IsType<ForeignResolution.KeepExisting>(resolution);
        Assert.Equal(0, outcome.Connections);
        Assert.Empty(outcome.ConnectionIds);
    }

    [Fact]
    public async Task AnAppWithNothingToReadFailsWithItsCode()
    {
        var failure = await Assert.ThrowsAsync<TableProException>(() =>
            _core.ReadForeignAsync(
                ForeignApp.DBeaver, _dirs, null, new ForeignImportRequest(true, true), TestContext.Current.CancellationToken));

        Assert.Equal("foreign_import.file_not_found", failure.Code);
    }

    // DBeaver's workspace where it keeps it on the platform the test runs on.
    private string DBeaverProject()
    {
        var root = OperatingSystem.IsMacOS() ? Path.Combine(_directory, "Library")
            : OperatingSystem.IsWindows() ? _dirs.Config
            : _dirs.Data;
        return Path.Combine(root, "DBeaverData", "workspace6", "General");
    }

    private void WriteDBeaver()
    {
        var project = DBeaverProject();
        var metadata = Path.Combine(project, ".dbeaver");
        Directory.CreateDirectory(metadata);
        Directory.CreateDirectory(Path.Combine(project, "Scripts"));
        File.WriteAllText(Path.Combine(metadata, "data-sources.json"), """
            {"connections": {"windows": {"provider": "postgresql", "name": "Windows PG",
              "configuration": {"host": "windows.example.com", "port": "5432", "database": "app"}}}}
            """);
        File.WriteAllBytes(
            Path.Combine(metadata, "credentials-config.json"),
            Encrypt("""{"windows": {"#connection": {"user": "winuser", "password": "windows-pass"}}}"""));
        File.WriteAllText(
            Path.Combine(metadata, "project-metadata.json"),
            """{"resources":{"Scripts/Report.sql":{"default-datasource":"windows"}}}""");
        File.WriteAllText(Path.Combine(project, "Scripts", "Report.sql"), "select 42;");
    }

    private static byte[] Encrypt(string json)
    {
        using var aes = Aes.Create();
        aes.Key = DBeaverKey;
        aes.GenerateIV();
        var cipher = aes.EncryptCbc(Encoding.UTF8.GetBytes(json), aes.IV, PaddingMode.PKCS7);
        return [.. aes.IV, .. cipher];
    }
}
