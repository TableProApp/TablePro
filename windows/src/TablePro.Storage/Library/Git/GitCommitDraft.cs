namespace TablePro.Storage.Library.Git;

/// <summary>A changed file offered in the commit dialog.</summary>
public sealed record GitCommitEntry(string Path, string FolderRelativePath, string? OriginalPath, GitFileStatus Status)
{
    public bool CanCommit => !Status.IsConflicted;

    /// <summary>The path to read the committed text from: a rename's old path, otherwise the file's own.</summary>
    public string ComparedPath => Status.Staged is GitChange.Renamed or GitChange.Copied ? OriginalPath ?? Path : Path;

    /// <summary><c>.A</c> is a file added with <c>git add --intent-to-add</c>: in the index, but not in HEAD either.</summary>
    public bool IsNewFile => Status.IsUntracked || Status.Staged == GitChange.Added || Status.Unstaged == GitChange.Added;
}

/// <summary>
/// The commit dialog's state for one linked folder: which changed files under it are checked and the message.
/// Built from the repository-wide status so a rename that crosses the folder's edge is handled the way git sees it.
/// </summary>
public sealed class GitCommitDraft
{
    private readonly HashSet<string> _checked;

    /// <param name="records">The repository's status.</param>
    /// <param name="prefix">The linked folder's path from the top level, from <see cref="GitRepositoryInfo.Prefix"/>.</param>
    /// <param name="preselecting">A file to check alone, by its path inside the folder; null checks every committable file.</param>
    public GitCommitDraft(IEnumerable<GitStatusRecord> records, string prefix, string? preselecting = null)
    {
        Prefix = prefix;
        var seen = new HashSet<string>(StringComparer.Ordinal);

        // An index deletion and an untracked file at the same path are two status records for one file; the
        // tracked one sorts first so it is the one kept.
        Entries =
        [
            .. records
                .Where(r => r.Path.StartsWith(prefix, StringComparison.Ordinal))
                .OrderBy(r => r.Status.IsUntracked ? 1 : 0)
                .Where(r => seen.Add(r.Path))
                .Select(r => new GitCommitEntry(r.Path, r.Path[prefix.Length..], r.OriginalPath, r.Status))
                .OrderBy(e => e.FolderRelativePath, StringComparer.CurrentCultureIgnoreCase),
        ];

        var committable = Entries.Where(e => e.CanCommit).ToList();
        _checked = preselecting is not null && committable.FirstOrDefault(e => e.FolderRelativePath == preselecting) is { } only
            ? new HashSet<string>([only.Path], StringComparer.Ordinal)
            : new HashSet<string>(committable.Select(e => e.Path), StringComparer.Ordinal);
    }

    public string Prefix { get; }

    public IReadOnlyList<GitCommitEntry> Entries { get; }

    public string Message { get; set; } = string.Empty;

    public IReadOnlyList<GitCommitEntry> CheckedEntries => [.. Entries.Where(e => e.CanCommit && _checked.Contains(e.Path))];

    public bool CanCommit => CheckedEntries.Count > 0 && !string.IsNullOrWhiteSpace(Message);

    /// <summary>
    /// The paths handed to <c>git commit --only</c>. A staged rename brings its old path along, unless that path is
    /// outside the folder or listed again because a new file sits there: then its own checkbox decides.
    /// </summary>
    public IReadOnlyList<string> CommitPaths
    {
        get
        {
            var listed = Entries.Select(e => e.Path).ToHashSet(StringComparer.Ordinal);
            var checkedEntries = CheckedEntries;
            var renamedFrom = checkedEntries
                .Where(e => e.Status.Staged == GitChange.Renamed && e.OriginalPath is { } original
                    && original.StartsWith(Prefix, StringComparison.Ordinal) && !listed.Contains(original))
                .Select(e => e.OriginalPath!);
            return [.. checkedEntries.Select(e => e.Path), .. renamedFrom];
        }
    }

    public IReadOnlyList<string> UntrackedPaths => [.. CheckedEntries.Where(e => e.Status.IsUntracked).Select(e => e.Path)];

    public bool IsChecked(GitCommitEntry entry) => entry.CanCommit && _checked.Contains(entry.Path);

    public void SetChecked(GitCommitEntry entry, bool isChecked)
    {
        if (!entry.CanCommit)
        {
            return;
        }

        if (isChecked)
        {
            _checked.Add(entry.Path);
        }
        else
        {
            _checked.Remove(entry.Path);
        }
    }
}
