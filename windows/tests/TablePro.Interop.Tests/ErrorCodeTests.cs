namespace TablePro.Interop.Tests;

public sealed class ErrorCodeTests
{
    [Fact]
    public async Task AMissingFileNamesEveryLayerAndThePath()
    {
        using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());
        var path = Path.Combine(Path.GetTempPath(), $"tablepro-missing-{Guid.NewGuid():N}.sqlite");

        var error = await Assert.ThrowsAsync<TableProException>(
            () => core.OpenFileAsync(new FileOpenOptions(path), TestContext.Current.CancellationToken));

        Assert.Equal("driver.file_not_found", error.Code);
        Assert.Equal(["connect.driver", "driver.file_not_found"], error.Error.Codes);
        Assert.Equal(Path.GetFileName(path), Path.GetFileName(error.Error.Path));
    }

    [Fact]
    public async Task ARelativePathIsAConfigurationError()
    {
        using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());

        var error = await Assert.ThrowsAsync<TableProException>(
            () => core.OpenFileAsync(new FileOpenOptions("relative.sqlite"), TestContext.Current.CancellationToken));

        Assert.Equal("config.relative_path", error.Code);
    }

    [Fact]
    public async Task AnEngineTheCoreDoesNotLinkIsNamed()
    {
        using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());
        var path = Path.Combine(Path.GetTempPath(), "tablepro-any.sqlite");

        var error = await Assert.ThrowsAsync<TableProException>(
            () => core.OpenFileAsync(
                new FileOpenOptions(path, EngineId: "oracle"),
                TestContext.Current.CancellationToken));

        Assert.Equal("connect.unknown_driver", error.Code);
    }

    [Fact]
    public async Task AStatementTheServerRefusesEndsTheRunWithTheServersWords()
    {
        await using var database = await SqliteDatabase.CreateAsync();

        using var run = database.Editor.Run(
            "SELECT * FROM nope",
            cancellationToken: TestContext.Current.CancellationToken);
        var outcome = await run.Completion;

        var failed = Assert.IsType<QueryOutcome.Failed>(outcome);
        Assert.Equal("driver.server", failed.Error.Code);
        Assert.NotNull(failed.Error.Server);
        Assert.Contains("no such table", failed.Error.Server.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ACellOutsideTheSetIsOutOfRange()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var run = database.Editor.Run(
            "SELECT id FROM people",
            cancellationToken: TestContext.Current.CancellationToken);
        await run.Completion;
        using var set = run.GetResultSet(0)!;

        var error = Assert.Throws<TableProException>(() => set.GetCellText(SqliteDatabase.PeopleRows, 0));

        Assert.Equal("ffi.out_of_range", error.Code);
    }
}
