namespace TablePro.Storage.Library.Git;

/// <summary>One side of a porcelain v2 <c>XY</c> code.</summary>
public enum GitChange
{
    Unmodified,
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    TypeChanged,
    Unmerged,
}

/// <summary>The letter shown beside a changed file.</summary>
public enum GitBadge
{
    Modified,
    Added,
    Renamed,
    Untracked,
    Conflicted,
}

/// <summary>A file's state in the index and the working tree, as <c>git status --porcelain=v2</c> reports it.</summary>
public readonly record struct GitFileStatus(GitChange Staged, GitChange Unstaged, bool IsUntracked = false, bool IsUnmergedEntry = false)
{
    public static GitFileStatus Untracked { get; } = new(GitChange.Unmodified, GitChange.Unmodified, IsUntracked: true);

    public bool IsConflicted => IsUnmergedEntry || Staged == GitChange.Unmerged || Unstaged == GitChange.Unmerged;

    public bool HasStagedChanges => !IsUntracked && Staged != GitChange.Unmodified;

    public bool HasUnstagedChanges => IsUntracked || Unstaged != GitChange.Unmodified;

    public GitBadge Badge
    {
        get
        {
            if (IsConflicted)
            {
                return GitBadge.Conflicted;
            }

            if (IsUntracked)
            {
                return GitBadge.Untracked;
            }

            return Staged switch
            {
                GitChange.Added => GitBadge.Added,
                GitChange.Renamed or GitChange.Copied => GitBadge.Renamed,
                _ => Unstaged == GitChange.Added ? GitBadge.Added : GitBadge.Modified,
            };
        }
    }

    public bool CanDiscardChanges => !IsUntracked && !IsConflicted && Unstaged is GitChange.Modified or GitChange.TypeChanged;

    /// <summary>
    /// Whether some commit holds this file. <c>.A</c> is <c>git add --intent-to-add</c>: listed in the index, in no
    /// commit yet.
    /// </summary>
    public bool HasCommittedHistory =>
        !IsUntracked && Unstaged != GitChange.Added && Staged is not (GitChange.Added or GitChange.Renamed or GitChange.Copied);

    public string AccessibleDescription
    {
        get
        {
            var label = BadgeLabel(Badge);
            if (IsUntracked || IsConflicted)
            {
                return label;
            }

            return (HasStagedChanges, Unstaged != GitChange.Unmodified) switch
            {
                (true, false) => label + ", staged",
                (true, true) => label + ", partly staged",
                _ => label,
            };
        }
    }

    public static GitChange ChangeFromCode(char code) => code switch
    {
        'M' => GitChange.Modified,
        'A' => GitChange.Added,
        'D' => GitChange.Deleted,
        'R' => GitChange.Renamed,
        'C' => GitChange.Copied,
        'T' => GitChange.TypeChanged,
        'U' => GitChange.Unmerged,
        _ => GitChange.Unmodified,
    };

    public static GitFileStatus FromCode(ReadOnlySpan<char> code, bool isUnmergedEntry = false) => new(
        ChangeFromCode(code.Length > 0 ? code[0] : '.'),
        ChangeFromCode(code.Length > 1 ? code[1] : '.'),
        IsUnmergedEntry: isUnmergedEntry);

    public static string BadgeLetter(GitBadge badge) => badge switch
    {
        GitBadge.Modified => "M",
        GitBadge.Added => "A",
        GitBadge.Renamed => "R",
        GitBadge.Untracked => "U",
        _ => "!",
    };

    public static string BadgeLabel(GitBadge badge) => badge switch
    {
        GitBadge.Modified => "Modified",
        GitBadge.Added => "Added",
        GitBadge.Renamed => "Renamed",
        GitBadge.Untracked => "Untracked",
        _ => "Conflicted",
    };
}
