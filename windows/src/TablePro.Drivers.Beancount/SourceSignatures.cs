namespace TablePro.Drivers.Beancount;

/// <summary>
/// What a path looked like when the projection was built: a file's size and write time, a directory's entries, or
/// absence. Any difference means the ledger may have changed.
/// </summary>
internal readonly record struct SourceSignature(DateTime? LastWriteUtc, long? Length, string? DirectoryEntries);

internal static class SourceSignatures
{
    public static Dictionary<string, SourceSignature> Read(IReadOnlyList<string> paths)
    {
        var signatures = new Dictionary<string, SourceSignature>(paths.Count, StringComparer.OrdinalIgnoreCase);
        foreach (var path in paths)
        {
            signatures[path] = Read(path);
        }

        return signatures;
    }

    public static bool Equal(IReadOnlyDictionary<string, SourceSignature> left, IReadOnlyDictionary<string, SourceSignature> right)
    {
        if (left.Count != right.Count)
        {
            return false;
        }

        foreach (var (path, signature) in left)
        {
            if (!right.TryGetValue(path, out var other) || other != signature)
            {
                return false;
            }
        }

        return true;
    }

    private static SourceSignature Read(string path)
    {
        try
        {
            var directory = new DirectoryInfo(path);
            if (directory.Exists)
            {
                var names = new List<string>();
                foreach (var entry in directory.EnumerateFileSystemInfos())
                {
                    names.Add(entry.Name);
                }

                names.Sort(StringComparer.Ordinal);
                return new SourceSignature(directory.LastWriteTimeUtc, null, string.Join('\n', names));
            }

            var file = new FileInfo(path);
            return file.Exists ? new SourceSignature(file.LastWriteTimeUtc, file.Length, null) : default;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return default;
        }
    }
}
