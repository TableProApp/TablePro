namespace TablePro.App.Model;

// File > Open Recent, newest first; one entry per path whatever its case, since Windows paths ignore case.
public sealed class RecentFiles
{
    public const int Limit = 10;

    private readonly List<string> _paths = [];

    public RecentFiles(IEnumerable<string>? paths = null)
    {
        foreach (var path in paths ?? [])
        {
            if (_paths.Count < Limit && !string.IsNullOrWhiteSpace(path) && !_paths.Exists(kept => Same(kept, path)))
            {
                _paths.Add(path);
            }
        }
    }

    // A copy, so a session that keeps it does not change with the list.
    public IReadOnlyList<string> Paths => [.. _paths];

    public void Add(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        Remove(path);
        _paths.Insert(0, path);
        if (_paths.Count > Limit)
        {
            _paths.RemoveRange(Limit, _paths.Count - Limit);
        }
    }

    public bool Remove(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        return _paths.RemoveAll(kept => Same(kept, path)) > 0;
    }

    public void Clear() => _paths.Clear();

    public bool RemoveMissing(Func<string, bool>? exists = null)
    {
        var present = exists ?? File.Exists;
        return _paths.RemoveAll(path => !present(path)) > 0;
    }

    private static bool Same(string kept, string path) => string.Equals(kept, path, StringComparison.OrdinalIgnoreCase);
}
