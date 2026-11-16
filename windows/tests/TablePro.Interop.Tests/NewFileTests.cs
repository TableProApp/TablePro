namespace TablePro.Interop.Tests;

public sealed class NewFileTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-new-file-").FullName;
    private readonly TableProCore _core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());

    public void Dispose()
    {
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // The database closes on the core's own threads, which can still hold it here on Windows.
        }
    }

    // As the connection form's New file does: make the file, close it, then connect to it as saved.
    [Theory]
    [InlineData("duckdb", "made.duckdb")]
    [InlineData("sqlite", "made.sqlite")]
    public async Task ANewFileIsMadeEmptyAndOpensAgainForWriting(string engine, string name)
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var path = Path.Combine(_directory, name);

        var made = await _core.OpenFileAsync(new FileOpenOptions(path, engine, Create: true), cancellationToken);
        await made.DisposeAsync();

        Assert.True(File.Exists(path));
        Assert.DoesNotContain(Directory.GetFiles(_directory), file => Path.GetFileName(file).StartsWith('.'));
        await using var session = await _core.OpenFileAsync(new FileOpenOptions(path, engine), cancellationToken);
        Assert.Equal(engine, session.EngineId);
        Assert.Empty(await session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken));
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        using var run = editor.Run("CREATE TABLE notes (body TEXT)");
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
    }
}
