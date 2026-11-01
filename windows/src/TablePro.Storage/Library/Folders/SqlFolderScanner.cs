namespace TablePro.Storage.Library.Folders;

/// <summary>One folder's files at the time of a scan. <see cref="Exists"/> is false when the folder is gone or unreadable.</summary>
public sealed record SqlFolderScan(LinkedSqlFolder Folder, bool Exists, IReadOnlyList<LinkedSqlFile> Files);

/// <summary>Lists the SQL files under a linked folder and reads each one's header.</summary>
public static class SqlFolderScanner
{
    /// <summary>The extensions the macOS app treats as SQL files.</summary>
    public static readonly IReadOnlySet<string> SupportedExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".sql", ".psql", ".pgsql" };

    public static bool IsSqlFile(string path) => SupportedExtensions.Contains(Path.GetExtension(path));

    public static SqlFolderScan Scan(LinkedSqlFolder folder, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(folder);
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder.ExpandedPath));
        if (!System.IO.Directory.Exists(root))
        {
            return new SqlFolderScan(folder, false, []);
        }

        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,

            // Hidden folders hold tool state (.git, .vscode, .idea) rather than queries, as on macOS.
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,

            // Reparse points are followed because OneDrive's cloud files are reparse points; the depth cap is what
            // stops a junction that points back up the tree.
            MaxRecursionDepth = 32,
        };

        var files = new List<LinkedSqlFile>();
        try
        {
            foreach (var path in System.IO.Directory.EnumerateFiles(root, "*", options))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!IsSqlFile(path) || HasDotSegment(root, path))
                {
                    continue;
                }

                if (Read(folder.Id, root, path) is { } file)
                {
                    files.Add(file);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new SqlFolderScan(folder, false, []);
        }

        files.Sort((a, b) => string.Compare(a.RelativePath, b.RelativePath, StringComparison.CurrentCultureIgnoreCase));
        return new SqlFolderScan(folder, true, files);
    }

    /// <summary>One file's entry, or null when it vanished or cannot be read.</summary>
    public static LinkedSqlFile? Read(Guid folderId, string folderRoot, string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                return null;
            }

            var header = SqlTextFile.ReadHeader(path);
            var metadata = SqlFrontmatter.Parse(header.Text);
            var relative = Path.GetRelativePath(folderRoot, path).Replace('\\', '/');
            return new LinkedSqlFile
            {
                FolderId = folderId,
                FullPath = info.FullName,
                RelativePath = relative,
                Name = string.IsNullOrWhiteSpace(metadata.Name) ? Path.GetFileNameWithoutExtension(path) : metadata.Name.Trim(),
                Keyword = metadata.Keyword,
                Description = metadata.Description,
                Modified = info.LastWriteTimeUtc,
                Size = info.Length,
                EncodingName = header.EncodingName,
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // A folder whose name starts with a dot is hidden on macOS whatever its attributes say, and Windows tools such
    // as git create them without the hidden attribute.
    private static bool HasDotSegment(string root, string path) =>
        Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar).Any(s => s.StartsWith('.'));
}
