namespace TablePro.Storage.Tests;

/// <summary>A fresh folder per test, so no test reads another's files or the user's real data.</summary>
internal sealed class TempDirectory : IDisposable
{
    public TempDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "TablePro.Storage.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
        Paths = new AppPaths(Path);
    }

    public string Path { get; }

    public AppPaths Paths { get; }

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
