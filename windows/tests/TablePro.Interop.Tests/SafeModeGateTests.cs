namespace TablePro.Interop.Tests;

public sealed class SafeModeGateTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-safe-mode-").FullName;
    private readonly TableProCore _core;

    public SafeModeGateTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", _directory), new MemorySecretStore());
    }

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    [Fact]
    public async Task ConfirmWritesAsksAboutEachWriteAndNeverAboutARead()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await using var session = await ConnectAsync(database.Path, SafeMode.ConfirmWrites, cancellationToken);

        var script = session.GateRun("SELECT 1; UPDATE people SET name = 'Ada' WHERE id = 1; DELETE FROM people");
        var read = session.GateRun("SELECT * FROM people");

        Assert.Equal(["UPDATE people SET name = 'Ada' WHERE id = 1", "DELETE FROM people"], script.Confirm);
        Assert.True(script.Destructive);
        Assert.False(script.Refused);
        Assert.Empty(read.Confirm);
        Assert.False(read.Refused);
    }

    [Fact]
    public async Task OffAsksOnlyBeforeAStatementThatEmptiesATable()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        var insert = database.Session.GateRun("INSERT INTO people (name) VALUES ('Ada')");
        var delete = database.Session.GateRun("DELETE FROM people");

        Assert.Empty(insert.Confirm);
        Assert.Equal(["DELETE FROM people"], delete.Confirm);
        Assert.True(delete.Destructive);
    }

    [Fact]
    public async Task AFileOpenedReadOnlyKeepsAWriteBack()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await using var session = await _core.OpenFileAsync(
            new FileOpenOptions(database.Path, ReadOnly: true),
            cancellationToken);

        var write = session.GateRun("SELECT 1; INSERT INTO people (name) VALUES ('Ada')");
        var read = session.GateRun("SELECT * FROM people");

        Assert.True(write.Refused);
        Assert.Empty(write.Confirm);
        Assert.False(read.Refused);
    }

    [Fact]
    public async Task ALevelSetOnAnOpenSessionAppliesAtOnceButNeverAcrossReadOnly()
    {
        const string Update = "UPDATE people SET name = 'Ada' WHERE id = 1";
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await using var session = await ConnectAsync(database.Path, SafeMode.Off, cancellationToken);

        var atOff = session.GateRun(Update);
        var confirmed = session.SetSafeMode(SafeMode.ConfirmWrites);
        var asked = session.GateRun(Update);
        var readOnly = session.SetSafeMode(SafeMode.ReadOnly);
        var stillAsked = session.GateRun(Update);

        Assert.Empty(atOff.Confirm);
        Assert.True(confirmed);
        Assert.Equal([Update], asked.Confirm);
        Assert.False(readOnly);
        Assert.False(stillAsked.Refused);
        Assert.Equal([Update], stillAsked.Confirm);
    }

    [Fact]
    public async Task ASessionThatCannotTakeReadOnlyStillAsksBeforeEveryWrite()
    {
        const string Update = "UPDATE people SET name = 'Ada' WHERE id = 1";
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await using var session = await ConnectAsync(database.Path, SafeMode.Off, cancellationToken);

        var readOnly = session.SetSafeMode(SafeMode.ReadOnly);
        var meanwhile = session.SetSafeMode(SafeMode.ConfirmWrites);
        var gate = session.GateRun(Update);

        Assert.False(readOnly);
        Assert.True(meanwhile);
        Assert.Equal([Update], gate.Confirm);
    }

    private async Task<DatabaseSession> ConnectAsync(string path, SafeMode safeMode, CancellationToken cancellationToken)
    {
        var saved = await _core.Library.SaveAsync(
            new SavedConnection(
                null, "app", "sqlite", string.Empty, 0, path, string.Empty, TlsSettings.Disabled, safeMode),
            ConnectionSecrets.None);
        return await _core.ConnectAsync(saved.Id!.Value, cancellationToken: cancellationToken);
    }
}
