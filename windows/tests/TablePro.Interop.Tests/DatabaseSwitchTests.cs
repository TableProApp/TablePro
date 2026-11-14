namespace TablePro.Interop.Tests;

// A file reaches one database, so what moves a tab or a connection to another refuses here, with the core's code.
public sealed class DatabaseSwitchTests
{
    [Fact]
    public async Task AFileHasOneDatabaseAndListsNoOthers()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();

        var listing = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.GetDatabasesAsync(cancellationToken));

        Assert.Equal(DatabaseLayout.OneDatabase, database.Session.Layout);
        Assert.Null(database.Session.Database);
        Assert.Equal("driver.unsupported", listing.Error.Code);
    }

    [Fact]
    public async Task AnEditorAskedForAnotherDatabaseOfAFileIsRefusedAndNotLeftOpen()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();

        var refused = await Assert.ThrowsAsync<TableProException>(
            () => database.Session.OpenEditorAsync("shop", cancellationToken));
        await using var editor = await database.Session.OpenEditorAsync(null, cancellationToken);

        Assert.Equal("driver.unsupported", refused.Error.Code);
        Assert.Null(editor.Database);
    }

    [Fact]
    public async Task AKeyOfAnEngineWithoutKeysIsRefused()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var reader = database.Session.OpenKey("people");

        var refused = await Assert.ThrowsAsync<TableProException>(() => reader.ReadMoreAsync(cancellationToken));

        Assert.Equal("people", reader.Key);
        Assert.Null(reader.GetRows());
        Assert.Contains("driver.unsupported", refused.Error.Codes);
    }

    [Fact]
    public async Task ATablePageOfAnEngineThatSeeksHandsBackNoResume()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();

        using var page = await database.Session.ReadTablePageAsync(
            new TableName(null, "people"), null, null, 2, 1, cancellationToken: cancellationToken);
        var outcome = await page.Run.Completion;

        Assert.IsType<QueryOutcome.Completed>(outcome);
        Assert.True(page.CanSeek);
        Assert.Null(page.NextPage());
    }
}
