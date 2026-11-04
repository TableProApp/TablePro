namespace TablePro.App.UITests;

internal sealed class PackageTestState
{
    private readonly HashSet<string> _ownedFolders = new(StringComparer.OrdinalIgnoreCase);

    public void Prepare(string folder)
    {
        folder = Path.GetFullPath(folder);
        var state = new DirectoryInfo(folder);
        if (!_ownedFolders.Contains(folder))
        {
            if (state.Exists && state.EnumerateFileSystemInfos().Any())
            {
                throw new InvalidOperationException("Package tests need empty LocalState. Use a fresh installation in a test account.");
            }

            state.Create();
            _ownedFolders.Add(folder);
            return;
        }

        // Only state claimed empty by this process may be reset for the next theme.
        foreach (var file in state.EnumerateFiles())
        {
            file.Delete();
        }

        foreach (var directory in state.EnumerateDirectories())
        {
            directory.Delete(recursive: true);
        }
    }
}
