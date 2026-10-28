namespace TablePro.Storage.Library.History;

/// <summary>Which version an entry stands for: the text as it is now, a snapshot taken on save, or a Git commit.</summary>
public abstract record VersionReference
{
    public static CurrentVersion Current { get; } = new();

    /// <summary>The first seven characters of a commit, or null for other versions.</summary>
    public virtual string? ShortRevision => null;
}

public sealed record CurrentVersion : VersionReference;

/// <summary>A copy the app kept when the file was saved.</summary>
public sealed record SnapshotVersion(long Id) : VersionReference;

/// <summary>The file as committed, at the path it had in that commit.</summary>
public sealed record GitRevisionVersion(string Commit, string Path) : VersionReference
{
    public override string? ShortRevision => Commit[..Math.Min(7, Commit.Length)];
}

public sealed record VersionEntry(VersionReference Reference, DateTimeOffset? Date, string? Summary = null, string? Author = null, bool HasUncommittedChanges = false)
{
    public bool IsCurrent => Reference is CurrentVersion;
}

/// <summary>Something the list should say about what it shows or leaves out.</summary>
public abstract record VersionHistoryNotice
{
    public abstract string Text { get; }
}

public sealed record KeepsLatestSnapshotsNotice(int Count) : VersionHistoryNotice
{
    public override string Text => FormattableString.Invariant($"TablePro keeps the latest {Count} saved versions of a file.");
}

public sealed record ShowsLatestCommitsNotice(int Count) : VersionHistoryNotice
{
    public override string Text => FormattableString.Invariant($"Showing the latest {Count} commits.");
}

public sealed record GitHistoryUnavailableNotice(string Reason) : VersionHistoryNotice
{
    public override string Text => Reason;
}

public sealed record VersionPage(IReadOnlyList<VersionEntry> Entries, IReadOnlyList<VersionHistoryNotice> Notices)
{
    public static VersionPage Empty { get; } = new([], []);

    public VersionEntry? Current => Entries.FirstOrDefault(e => e.IsCurrent);

    /// <summary>What a version is compared with: the newest past version for the current one, the current one for any past one.</summary>
    public VersionEntry? BaselineFor(VersionReference reference) =>
        reference is CurrentVersion ? Entries.FirstOrDefault(e => !e.IsCurrent) : Current;
}

public enum VersionHistoryError
{
    SubjectNotFound,
    VersionNotFound,
    GitUnavailable,
    NotInRepository,
    CommandFailed,
    UndecodableContent,
    StoredInLargeFileStorage,
    FileChangedBeforeWriting,
    RestoreFailed,
}

public sealed class VersionHistoryException : Exception
{
    public VersionHistoryException()
        : this(VersionHistoryError.VersionNotFound)
    {
    }

    public VersionHistoryException(string message)
        : this(VersionHistoryError.CommandFailed, message)
    {
    }

    public VersionHistoryException(string message, Exception innerException)
        : base(message, innerException)
    {
        Error = VersionHistoryError.CommandFailed;
    }

    public VersionHistoryException(VersionHistoryError error, string? detail = null, Exception? innerException = null)
        : base(Describe(error, detail), innerException)
    {
        Error = error;
    }

    public VersionHistoryError Error { get; }

    private static string Describe(VersionHistoryError error, string? detail) => error switch
    {
        VersionHistoryError.SubjectNotFound => "This file no longer exists.",
        VersionHistoryError.VersionNotFound => "This version is no longer available.",
        VersionHistoryError.GitUnavailable => "Git is not installed. Install Git for Windows to see the file's commits.",
        VersionHistoryError.NotInRepository => "This file is not in a Git repository.",
        VersionHistoryError.UndecodableContent => "This version is not readable as text.",
        VersionHistoryError.StoredInLargeFileStorage => "This file is stored with Git LFS. Restore it with your Git client.",
        VersionHistoryError.FileChangedBeforeWriting => "The file or its staged version changed before it could be written. Nothing was replaced.",
        VersionHistoryError.RestoreFailed => "The version could not be restored: " + detail,
        _ => detail ?? "Git failed.",
    };
}

/// <summary>A restore checked and ready to write. <see cref="ReplacesUncommittedChanges"/> says the user should be asked first.</summary>
public sealed record VersionRestorePlan(bool ReplacesUncommittedChanges, Func<CancellationToken, Task> Apply);

/// <summary>Where a subject's versions come from.</summary>
public interface IVersionHistoryProvider
{
    Task<VersionPage> LoadHistoryAsync(CancellationToken cancellationToken = default);

    Task<string> ContentAsync(VersionReference reference, CancellationToken cancellationToken = default);

    Task<VersionRestorePlan> PrepareRestoreAsync(VersionReference reference, CancellationToken cancellationToken = default);
}
