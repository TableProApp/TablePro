namespace TablePro.Storage.Library.Folders;

/// <summary>
/// A folder of <c>.sql</c> files the app watches and lists beside the editor, as the macOS app's linked folders.
/// The files stay where they are; the app only remembers the folder.
/// </summary>
public sealed record LinkedSqlFolder
{
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>The folder as the user chose it. A leading <c>~</c> means the user's profile folder, as the macOS app stores it.</summary>
    public required string Path { get; init; }

    public bool IsEnabled { get; init; } = true;

    /// <summary>Shown only in this connection's windows, or in every window when null.</summary>
    public Guid? ConnectionId { get; init; }

    public string Name => System.IO.Path.GetFileName(ExpandedPath.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar)) is { Length: > 0 } name
        ? name
        : ExpandedPath;

    public string ExpandedPath => ExpandHome(Path);

    public bool IsVisibleTo(Guid? connectionId) => ConnectionId is null || ConnectionId == connectionId;

    public static string ExpandHome(string path)
    {
        if (path == "~")
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith(@"~\", StringComparison.Ordinal))
        {
            return System.IO.Path.GetFullPath(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]));
        }

        return path;
    }
}

/// <summary>The file <see cref="LinkedSqlFolderStore"/> keeps.</summary>
public sealed record LinkedSqlFoldersDocument
{
    public int Version { get; init; } = 1;

    public IReadOnlyList<LinkedSqlFolder> Folders { get; init; } = [];
}
