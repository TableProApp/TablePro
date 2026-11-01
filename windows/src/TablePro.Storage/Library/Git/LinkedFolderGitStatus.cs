using TablePro.Storage.Library.Folders;

namespace TablePro.Storage.Library.Git;

/// <summary>A linked file's Git state: committed and unchanged, or changed in the way its status says.</summary>
public readonly record struct LinkedFileGitState(GitFileStatus? Status)
{
    public static LinkedFileGitState Clean { get; } = new(null);

    public bool IsClean => Status is null;

    public bool HasCommittedHistory => Status?.HasCommittedHistory ?? true;

    public bool CanDiscardChanges => Status?.CanDiscardChanges ?? false;
}

/// <summary>A linked folder's repository and the Git state of the files under it, keyed by their path inside the folder.</summary>
public sealed record LinkedFolderGitSnapshot(GitRepositoryInfo Repository, string? Head, IReadOnlyDictionary<string, GitFileStatus> Statuses, IReadOnlySet<string> TrackedPaths)
{
    /// <summary>The file's state, or null when git neither tracks nor reports it (an ignored file).</summary>
    public LinkedFileGitState? StateOf(string relativePath)
    {
        if (Statuses.TryGetValue(relativePath, out var status))
        {
            return new LinkedFileGitState(status);
        }

        return TrackedPaths.Contains(relativePath) ? LinkedFileGitState.Clean : null;
    }
}

/// <summary>Reads the Git state of every linked folder that sits in a repository.</summary>
public static class LinkedFolderGitStatus
{
    /// <summary>
    /// One snapshot per folder in a repository. A folder whose status fails this time keeps its previous snapshot, so
    /// a git that is briefly busy does not make the badges flicker away.
    /// </summary>
    public static async Task<IReadOnlyDictionary<Guid, LinkedFolderGitSnapshot>> LoadAsync(
        IEnumerable<LinkedSqlFolder> folders,
        GitClient? client,
        IReadOnlyDictionary<Guid, LinkedFolderGitSnapshot>? previous = null,
        CancellationToken cancellationToken = default)
    {
        var loaded = new Dictionary<Guid, LinkedFolderGitSnapshot>();
        if (client is null)
        {
            return loaded;
        }

        foreach (var folder in folders.Where(f => f.IsEnabled))
        {
            var directory = folder.ExpandedPath;
            if (!Directory.Exists(directory))
            {
                continue;
            }

            try
            {
                if (await client.RepositoryInfoAsync(directory, cancellationToken) is not { } repository)
                {
                    continue;
                }

                var records = await client.StatusAsync(directory, cancellationToken: cancellationToken);
                var tracked = await client.TrackedFilesAsync(directory, cancellationToken);
                loaded[folder.Id] = new LinkedFolderGitSnapshot(
                    repository,
                    await client.HeadCommitAsync(directory, cancellationToken),
                    FolderRelativeStatuses(records, repository.Prefix),
                    FolderRelativePaths(tracked, repository.Prefix));
            }
            catch (Exception ex) when (ex is GitCommandException or GitProcessException)
            {
                if (previous?.TryGetValue(folder.Id, out var kept) == true)
                {
                    loaded[folder.Id] = kept;
                }
            }
        }

        return loaded;
    }

    public static IReadOnlyDictionary<string, GitFileStatus> FolderRelativeStatuses(IEnumerable<GitStatusRecord> records, string prefix)
    {
        var statuses = new Dictionary<string, GitFileStatus>(StringComparer.Ordinal);
        foreach (var record in records.Where(r => r.Path.StartsWith(prefix, StringComparison.Ordinal)))
        {
            statuses[record.Path[prefix.Length..]] = record.Status;
        }

        return statuses;
    }

    public static IReadOnlySet<string> FolderRelativePaths(IEnumerable<string> paths, string prefix) =>
        paths.Where(p => p.StartsWith(prefix, StringComparison.Ordinal)).Select(p => p[prefix.Length..]).ToHashSet(StringComparer.Ordinal);
}
